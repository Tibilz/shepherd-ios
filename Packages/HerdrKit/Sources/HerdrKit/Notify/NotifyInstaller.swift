import Foundation

/// How the service is kept alive: systemd user unit (needs linger), cron watchdog, or a
/// self-supervising background process that the app restarts on connect (after a server reboot).
public enum NotifyMode: String, Sendable { case systemd, cron, background, none }

public struct NotifyStatus: Equatable, Sendable {
    public var installed: Bool
    public var running: Bool
    public var mode: NotifyMode
    public var linger: Bool
    public var cron: Bool
    public var python: Bool
    public init(installed: Bool, running: Bool, mode: NotifyMode, linger: Bool, cron: Bool, python: Bool) {
        self.installed = installed
        self.running = running
        self.mode = mode
        self.linger = linger
        self.cron = cron
        self.python = python
    }
}

public enum NotifyError: Error, Equatable, LocalizedError {
    case pythonMissing, scriptMissing, configUnreadable, remote(String)
    public var errorDescription: String? {
        switch self {
        case .pythonMissing: "Auf dem Server fehlt python3. Installiere es z. B. mit: sudo apt install python3"
        case .scriptMissing: "Der Begleitdienst fehlt in der App."
        case .configUnreadable: "Die Konfiguration auf dem Server (~/.config/herdr-notify/config.json) ist nicht lesbar. Entferne die Benachrichtigungen und richte sie neu ein."
        case .remote(let m): "Auf dem Server ist ein Fehler aufgetreten: \(m)"
        }
    }
}

/// Installs, configures and removes herdr-notify on the server over a RemoteShell.
/// Touches only `<baseDir>/` and either `~/.config/systemd/user/<name>.service` or crontab lines marked `# <name>`.
public struct NotifyInstaller: Sendable {
    public let shell: RemoteShell
    public let baseDir: String

    public init(shell: RemoteShell, baseDir: String = "~/.config/herdr-notify") {
        precondition(baseDir.hasPrefix("~/.config/herdr-notify") && !baseDir.contains("..")
                     && baseDir.allSatisfy { $0.isLetter || $0.isNumber || "~/._-".contains($0) }, "unsafe baseDir")
        self.shell = shell
        self.baseDir = baseDir
    }

    public var name: String { (baseDir as NSString).lastPathComponent }

    /// `D` (absolute dir, from $HOME) and `N` (name) for every script.
    /// Printed before any script output; everything before it (motd, profile banners) is discarded.
    public static let marker = "__HERDR_NOTIFY_OUTPUT__"

    var prelude: String {
        "printf '%s\\n' \(Self.marker)\n" + "D=\"$HOME/\(baseDir.dropFirst(2))\"\nN=\(name)\n" + Self.oursFunction
    }

    /// `ours PIDFILE PATTERN`: the pid is alive and its command line matches (pids get reused).
    static let oursFunction = """
    ours() { p="$(cat "$1" 2>/dev/null)" || return 1; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && ps -p "$p" -o args= 2>/dev/null | grep -q -- "$2"; }

    """

    public static func bundledScript() -> String? {
        guard let url = Bundle.module.url(forResource: "herdr-notify", withExtension: "py") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func writeFile(_ content: String, to path: String) -> String {
        "printf %s \(Data(content.utf8).base64EncodedString()) | base64 -d > \(path)"
    }

    @discardableResult
    func run(_ script: String) async throws -> ExecResult {
        var res = try await shell.exec(SocketCommand.login(prelude + script))
        guard res.exitCode == 0 else {
            let err = String(decoding: res.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NotifyError.remote(err.isEmpty ? "Exit-Code \(res.exitCode)" : err)
        }
        res.stdout = Self.afterMarker(res.stdout)
        return res
    }

    static func afterMarker(_ out: Data) -> Data {
        let m = Data((marker + "\n").utf8)
        guard let r = out.range(of: m, options: .backwards) else { return out }
        return out.subdata(in: r.upperBound..<out.endIndex)
    }

    // MARK: - Status

    static let statusScript = """
    if [ -f "$D/herdr-notify.py" ]; then echo installed=1; else echo installed=0; fi
    if ours "$D/herdr-notify.pid" herdr-notify.py; then echo running=1; else echo running=0; fi
    if [ -f "$HOME/.config/systemd/user/$N.service" ]; then echo mode=systemd
    elif command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "# $N$"; then echo mode=cron
    elif [ -f "$D/mode" ]; then echo "mode=$(cat "$D/mode")"
    else echo mode=none; fi
    if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ]; then echo linger=1; else echo linger=0; fi
    if command -v crontab >/dev/null 2>&1; then echo cron=1; else echo cron=0; fi
    if command -v python3 >/dev/null 2>&1; then echo python=1; else echo python=0; fi
    """

    public func status() async throws -> NotifyStatus {
        let out = String(decoding: try await run(Self.statusScript).stdout, as: UTF8.self)
        var kv: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { kv[parts[0]] = parts[1] }
        }
        return NotifyStatus(installed: kv["installed"] == "1", running: kv["running"] == "1",
                            mode: NotifyMode(rawValue: kv["mode"] ?? "") ?? .none,
                            linger: kv["linger"] == "1", cron: kv["cron"] == "1", python: kv["python"] == "1")
    }

    /// What install() will do, shown to the user for confirmation.
    public func plannedActions(linger: Bool, cron: Bool) -> [String] {
        var a = ["Ordner \(baseDir) anlegen (Skript, Konfiguration, Log)"]
        switch Self.mode(linger: linger, cron: cron) {
        case .systemd:
            a.append("Dienst ~/.config/systemd/user/\(name).service anlegen und starten")
        case .cron:
            a.append("Zwei Zeilen „# \(name)“ zu deiner crontab hinzufügen (Start beim Booten, Wächter jede Minute)")
            a.append("Den Dienst sofort im Hintergrund starten")
        case .background, .none:
            a.append("Den Dienst als Hintergrundprozess starten (startet sich nach Abstürzen selbst neu)")
            a.append("Nach einem Neustart des Servers startet die App ihn beim nächsten Verbinden wieder")
        }
        a.append("Kein sudo, keine Änderungen außerhalb deines Home-Verzeichnisses")
        return a
    }

    // MARK: - Install / uninstall

    static func mode(linger: Bool, cron: Bool) -> NotifyMode { linger ? .systemd : (cron ? .cron : .background) }

    static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { preconditionFailure("missing resource \(name).\(ext)") }
        return text
    }

    /// Supervisor starter (Resources/run.sh): single instance via lock dir, pid + command-line check.
    static var runScript: String { resource("run", "sh") }
    /// crontab update (Resources/cron-install.sh); tolerant of an empty crontab under `set -e`.
    static var cronInstall: String { resource("cron-install", "sh") }

    func configJSON(_ c: NotifyConfig) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(c), as: UTF8.self)
    }

    public func install(config: NotifyConfig) async throws -> NotifyMode {
        let st = try await status()
        guard st.python else { throw NotifyError.pythonMissing }
        guard let script = Self.bundledScript() else { throw NotifyError.scriptMissing }
        var s = """
        set -e
        mkdir -p "$D"
        chmod 700 "$D"
        \(Self.writeFile(script, to: "\"$D/herdr-notify.py\""))
        \(Self.writeFile(Self.runScript, to: "\"$D/run.sh\""))
        chmod 755 "$D/run.sh"
        umask 077
        \(Self.writeFile(try configJSON(config), to: "\"$D/config.json\""))
        chmod 600 "$D/config.json"

        """
        let mode = Self.mode(linger: st.linger, cron: st.cron)
        if mode == .systemd {
            s += """
            mkdir -p "$HOME/.config/systemd/user"
            printf '[Unit]\\nDescription=herdr notifications (%s)\\n\\n[Service]\\nExecStart=/usr/bin/env python3 %s/herdr-notify.py --config %s/config.json\\nRestart=always\\nRestartSec=5\\n\\n[Install]\\nWantedBy=default.target\\n' "$N" "$D" "$D" > "$HOME/.config/systemd/user/$N.service"
            systemctl --user daemon-reload
            systemctl --user enable --now \(name)
            """
        } else if mode == .cron {
            s += """
            \(Self.cronInstall)
            "$D/run.sh"
            """
        } else {
            s += """
            echo background > "$D/mode"
            "$D/run.sh"
            """
        }
        try await run(s)
        return mode
    }

    public func uninstall() async throws {
        try await run("""
        case "$D" in *..*) exit 3;; esac
        case "$D" in "$HOME"/.config/herdr-notify*) ;; *) exit 3;; esac
        if [ -f "$HOME/.config/systemd/user/$N.service" ]; then
          systemctl --user disable --now "$N" 2>/dev/null || true
          rm -f "$HOME/.config/systemd/user/$N.service"
          systemctl --user daemon-reload 2>/dev/null || true
        fi
        if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "# $N$"; then crontab -l 2>/dev/null | grep -v "# $N$" | crontab -; fi
        ours "$D/supervisor.pid" "run.sh --supervise" && kill "$p" 2>/dev/null || true
        ours "$D/herdr-notify.pid" herdr-notify.py && kill "$p" 2>/dev/null || true
        rm -rf "$D"
        """)
    }

    /// Restarts a background-mode service after a server reboot (no-op otherwise or when running).
    /// systemd/cron modes are left alone so there is never a second instance.
    public func start() async throws {
        try await run(##"[ "$(cat "$D/mode" 2>/dev/null)" = background ] && [ -x "$D/run.sh" ] && "$D/run.sh" || true"##)
    }

    // MARK: - Config

    public func readConfig() async throws -> NotifyConfig? {
        let data = try await run(#"cat "$D/config.json" 2>/dev/null || true"#).stdout
        guard !data.isEmpty else { return nil }
        do { return try JSONDecoder().decode(NotifyConfig.self, from: data) }
        catch { throw NotifyError.configUnreadable }
    }

    public func writeConfig(_ c: NotifyConfig) async throws {
        try await run("""
        set -e
        mkdir -p "$D"
        umask 077
        \(Self.writeFile(try configJSON(c), to: "\"$D/config.json.tmp\""))
        chmod 600 "$D/config.json.tmp"
        mv "$D/config.json.tmp" "$D/config.json"
        chmod 600 "$D/config.json"
        """)
    }

    public func sendTest(config c: NotifyConfig) async throws {
        try await run("curl -fsS -m 10 -o /dev/null -H 'Title: herdr Test' -H 'Tags: bell' -d "
                      + ShellQuote.quote("Benachrichtigungen von \(c.serverName) funktionieren.") + " "
                      + ShellQuote.quote(c.subscribeURL.absoluteString))
    }
}
