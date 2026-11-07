import Foundation
import Testing
@testable import HerdrKit

func out(_ s: String, code: Int32 = 0) -> ExecResult { ExecResult(stdout: Data(s.utf8), stderr: Data(), exitCode: code) }

/// Decodes every `printf %s <b64> | base64 -d` payload embedded in a command.
func embeddedPayloads(_ command: String) -> [String] {
    let re = try! NSRegularExpression(pattern: "printf %s ([A-Za-z0-9+/=]+) \\| base64 -d")
    return re.matches(in: command, range: NSRange(command.startIndex..., in: command)).compactMap {
        Data(base64Encoded: String(command[Range($0.range(at: 1), in: command)!])).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// The inner script of `bash -lc '<script>'`, unquoted.
func innerScript(_ command: String) -> String {
    guard command.hasPrefix("bash -lc '") else { return command }
    return String(command.dropFirst(10).dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
}

let sampleConfig = NotifyConfig(ntfyTopic: "herdr-abcdefghijklmnopqrstuvwx", socket: "/home/ubuntu/.config/herdr/herdr.sock",
                                serverId: UUID(uuidString: "6B7D0C1E-2F3A-4B5C-8D9E-0F1A2B3C4D5E")!, serverName: "VPS 2")

@Suite struct NotifyConfigTests {
    @Test func configRoundTripMatchesPythonKeys() throws {
        let data = try JSONEncoder().encode(sampleConfig)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Keys from the bundled script's DEFAULT_CONFIG, via python3 on the Mac.
        let script = try #require(NotifyInstaller.bundledScript())
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hn-\(UUID()).py")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-B", "-c", "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('m',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(sorted(m.DEFAULT_CONFIG)))", tmp.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let pyKeys = try JSONDecoder().decode([String].self, from: pipe.fileHandleForReading.readDataToEndOfFile())
        #expect(obj.keys.sorted() == pyKeys)
        #expect(obj["ntfyToken"] is NSNull)
        #expect((obj["events"] as? [String: Bool]) == ["blocked": true, "done": true, "idle": false])
        #expect(try JSONDecoder().decode(NotifyConfig.self, from: data) == sampleConfig)
    }

    @Test func randomTopicFormat() {
        let t = NotifyConfig.randomTopic()
        #expect(t.range(of: "^herdr-[a-z0-9]{24}$", options: .regularExpression) != nil)
        #expect(NotifyConfig.randomTopic() != t)
    }

    @Test func agentSwitchFallsBackToDefault() {
        var c = sampleConfig
        c.agents = ["rev": false]
        #expect(!c.isEnabled(agent: "rev"))
        #expect(c.isEnabled(agent: "other"))
        c.defaultAgentEnabled = false
        #expect(!c.isEnabled(agent: "other"))
    }

    @Test func subscribeURL() {
        var c = sampleConfig
        c.ntfyServer = "https://ntfy.example.org/"
        #expect(c.subscribeURL.absoluteString == "https://ntfy.example.org/herdr-abcdefghijklmnopqrstuvwx")
    }
}

@Suite struct NotifyInstallerTests {
    @Test func scriptIsBundled() throws {
        let s = try #require(NotifyInstaller.bundledScript())
        #expect(s.hasPrefix("#!/usr/bin/env python3"))
    }

    @Test func statusParsing() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("installed=", out("installed=1\nrunning=0\nmode=cron\nlinger=0\ncron=1\npython=1\n"))]
        let st = try await NotifyInstaller(shell: shell).status()
        #expect(st == NotifyStatus(installed: true, running: false, mode: .cron, linger: false, cron: true, python: true))
    }

    @Test func installUsesCronWithoutLinger() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("installed=", out("installed=0\nrunning=0\nmode=none\nlinger=0\ncron=1\npython=1\n"))]
        let mode = try await NotifyInstaller(shell: shell).install(config: sampleConfig)
        #expect(mode == .cron)
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains("| crontab -"))
        #expect(cmd.contains("N=herdr-notify\n"))
        #expect(cmd.contains(#"# $N"; echo"#))
        #expect(!cmd.contains("systemctl"))
        let payloads = embeddedPayloads(cmd)
        #expect(payloads.contains { $0.hasPrefix("#!/usr/bin/env python3") })
        #expect(payloads.contains { $0.contains("\"ntfyTopic\":\"herdr-abcdefghijklmnopqrstuvwx\"") })
    }

    @Test func installUsesSystemdWithLinger() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("installed=", out("installed=0\nrunning=0\nmode=none\nlinger=1\npython=1\n"))]
        let mode = try await NotifyInstaller(shell: shell).install(config: sampleConfig)
        #expect(mode == .systemd)
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains("systemctl --user enable --now herdr-notify"))
        #expect(cmd.contains("Restart=always"))
        #expect(!cmd.contains("crontab -\n") && !cmd.contains("| crontab -"))
    }

    @Test func installUsesBackgroundWithoutCronOrLinger() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("installed=", out("installed=0\nrunning=0\nmode=none\nlinger=0\ncron=0\npython=1\n"))]
        let mode = try await NotifyInstaller(shell: shell).install(config: sampleConfig)
        #expect(mode == .background)
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(!cmd.contains("crontab"))
        #expect(!cmd.contains("systemctl"))
        #expect(cmd.contains(#"echo background > "$D/mode""#))
        #expect(cmd.hasSuffix(#""$D/run.sh""#))
    }

    @Test func runScriptSupervisesAndRestarts() {
        let r = NotifyInstaller.runScript
        #expect(r.contains("supervisor.pid"))
        #expect(r.contains("while :; do"))
        #expect(r.contains("sleep 5"))
    }

    @Test func startRunsRunScriptOnlyWhenInstalled() async throws {
        let shell = FakeShell()
        try await NotifyInstaller(shell: shell).start()
        let cmd = innerScript(try #require(shell.commands.last))
        // Only background mode is app-supervised; systemd/cron start it themselves (no duplicate instance).
        #expect(cmd.contains(##"[ "$(cat "$D/mode" 2>/dev/null)" = background ] && [ -x "$D/run.sh" ] && "$D/run.sh""##))
    }

    @Test func plannedActionsDescribeBackgroundMode() {
        let a = NotifyInstaller(shell: FakeShell()).plannedActions(linger: false, cron: false)
        #expect(a.contains { $0.contains("background process") })
        #expect(!a.contains { $0.contains("crontab") })
    }

    @Test func installRequiresPython() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("installed=", out("installed=0\nrunning=0\nmode=none\nlinger=0\npython=0\n"))]
        await #expect(throws: NotifyError.pythonMissing) { try await NotifyInstaller(shell: shell).install(config: sampleConfig) }
    }

    @Test func cronInstallPreservesForeignLines() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("installed=", out("installed=0\nrunning=0\nmode=none\nlinger=0\ncron=1\npython=1\n"))]
        _ = try await NotifyInstaller(shell: shell).install(config: sampleConfig)
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains(##"{ crontab -l 2>/dev/null | grep -v "# $N$" || true;"##))
    }

    @Test func uninstallRemovesOnlyOwnFiles() async throws {
        let shell = FakeShell()
        try await NotifyInstaller(shell: shell).uninstall()
        let cmd = innerScript(try #require(shell.commands.last))
        let rms = cmd.split(separator: "\n").filter { $0.contains("rm ") }
        #expect(!rms.isEmpty)
        for line in rms {
            #expect(line.contains("\"$D\"") || line.contains("systemd/user/$N.service"), "unexpected rm: \(line)")
        }
        #expect(cmd.contains(#"case "$D" in "$HOME"/.config/herdr-notify*) ;; *) exit 3;; esac"#))
        #expect(cmd.contains("supervisor.pid"))
    }

    @Test func pidChecksVerifyCommandLine() async throws {
        // A reused pid must neither count as "running" nor be killed by uninstall.
        #expect(NotifyInstaller.statusScript.contains(#"ours "$D/herdr-notify.pid" herdr-notify.py"#))
        let shell = FakeShell()
        try await NotifyInstaller(shell: shell).uninstall()
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains(#"ours "$D/supervisor.pid" "run.sh --supervise" && kill"#))
        #expect(cmd.contains(#"ours "$D/herdr-notify.pid" herdr-notify.py && kill"#))
        #expect(!cmd.contains(#"kill "$(cat"#))
    }

    @Test func uninstallRefusesDotDotPaths() async throws {
        let shell = FakeShell()
        try await NotifyInstaller(shell: shell).uninstall()
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains(#"case "$D" in *..*) exit 3;; esac"#))
    }

    @Test func customBaseDirChangesNameAndMarker() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("installed=", out("installed=0\nrunning=0\nmode=none\nlinger=0\npython=1\n"))]
        _ = try await NotifyInstaller(shell: shell, baseDir: "~/.config/herdr-notify-it").install(config: sampleConfig)
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains(#"D="$HOME/.config/herdr-notify-it""#))
        #expect(cmd.contains("N=herdr-notify-it"))
    }

    @Test func configWrittenWithMode600() async throws {
        let shell = FakeShell()
        try await NotifyInstaller(shell: shell).writeConfig(sampleConfig)
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains("umask 077"))
        #expect(cmd.contains(#"chmod 600 "$D/config.json""#))
    }

    /// Login shells may print a motd/banner before our output (bash -lc sources the profile).
    @Test func profileOutputBeforeMarkerIsIgnored() async throws {
        let shell = FakeShell()
        let motd = "Welcome to Ubuntu\ninstalled=0\nmode=none\n"
        shell.execHandlers = [("installed=", out(motd + NotifyInstaller.marker + "\ninstalled=1\nrunning=1\nmode=background\nlinger=0\ncron=0\npython=1\n"))]
        let st = try await NotifyInstaller(shell: shell).status()
        #expect(st.installed && st.running && st.mode == .background)
        let json = String(decoding: try JSONEncoder().encode(sampleConfig), as: UTF8.self)
        shell.execHandlers = [("config.json", out("neofetch {art}\n" + NotifyInstaller.marker + "\n" + json))]
        #expect(try await NotifyInstaller(shell: shell).readConfig() == sampleConfig)
    }

    @Test func scriptsPrintMarkerFirst() async throws {
        let shell = FakeShell()
        _ = try? await NotifyInstaller(shell: shell).status()
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains("printf '%s\\n' \(NotifyInstaller.marker)\n"))
    }

    @Test func unreadableConfigThrowsInsteadOfNil() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("config.json", out(NotifyInstaller.marker + "\n{kaputt"))]
        await #expect(throws: NotifyError.configUnreadable) { _ = try await NotifyInstaller(shell: shell).readConfig() }
    }

    @Test func readConfigParsesOrNil() async throws {
        let shell = FakeShell()
        let json = String(decoding: try JSONEncoder().encode(sampleConfig), as: UTF8.self)
        shell.execHandlers = [("config.json", out(json))]
        #expect(try await NotifyInstaller(shell: shell).readConfig() == sampleConfig)
        shell.execHandlers = [("config.json", out(""))]
        #expect(try await NotifyInstaller(shell: shell).readConfig() == nil)
    }

    @Test func sendTestQuotesTopic() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("curl", out(""))]
        try await NotifyInstaller(shell: shell).sendTest(config: sampleConfig)
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains("curl -fsS -m 10"))
        #expect(cmd.contains("'https://ntfy.sh/herdr-abcdefghijklmnopqrstuvwx'"))
    }

    @Test func sendTestFailureIsReported() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("curl", ExecResult(stdout: Data(), stderr: Data("curl: (6) Could not resolve host".utf8), exitCode: 6))]
        await #expect(throws: NotifyError.self) { try await NotifyInstaller(shell: shell).sendTest(config: sampleConfig) }
    }
}

@Suite struct AgentTransitionsTests {
    func snap(_ agents: [(String, String?, AgentStatus)]) -> HerdrSnapshot {
        HerdrSnapshot(workspaces: [], tabs: [], panes: [], agents: agents.map { pane, name, st in
            let json = #"{"pane_id":"\#(pane)","workspace_id":"w1","tab_id":"w1:t1","agent_status":"\#(st.rawValue)"\#(name.map { #","name":"\#($0)""# } ?? "")}"#
            return try! HerdrJSON.decoder.decode(Agent.self, from: Data(json.utf8))
        })
    }

    @Test func firstSnapshotHasNoTransitions() {
        #expect(AgentTransitions.diff(old: nil, new: snap([("w1:p1", "rev", .blocked)])).isEmpty)
    }

    @Test func toBlockedIsReported() {
        let t = AgentTransitions.diff(old: snap([("w1:p1", "rev", .working)]), new: snap([("w1:p1", "rev", .blocked)]))
        #expect(t == [AgentTransition(target: "rev", name: "rev", to: .blocked)])
    }

    @Test func stayingBlockedIsSilent() {
        #expect(AgentTransitions.diff(old: snap([("w1:p1", "rev", .blocked)]), new: snap([("w1:p1", "rev", .blocked)])).isEmpty)
    }

    @Test func toWorkingIsSilent() {
        #expect(AgentTransitions.diff(old: snap([("w1:p1", "rev", .blocked)]), new: snap([("w1:p1", "rev", .working)])).isEmpty)
    }

    @Test func doneReported() {
        let t = AgentTransitions.diff(old: snap([("w1:p1", nil, .working)]), new: snap([("w1:p1", nil, .done)]))
        #expect(t == [AgentTransition(target: "w1:p1", name: "w1:p1", to: .done)])
    }

    @Test func newAgentAlreadyBlockedIsReported() {
        let t = AgentTransitions.diff(old: snap([]), new: snap([("w2:p1", "b", .blocked)]))
        #expect(t.map(\.target) == ["b"])
    }
}

@MainActor @Suite struct LiveSessionTransitionTests {
    @Test func callbackReceivesTransitions() async throws {
        let shell = try runningShell()
        let s = LiveSession(client: HerdrClient(shell: shell), pollInterval: .seconds(60))
        var got: [AgentTransition] = []
        s.onTransitions = { got += $0 }
        await s.start()
        #expect(got.isEmpty)
        shell.responses["agent.list"] = try String(decoding: fixture("agent_list"), as: UTF8.self)
            .replacingOccurrences(of: #""agent_status":"working""#, with: #""agent_status":"done""#)
        await s.refresh()
        #expect(got.map(\.to) == [.done])
        s.stop()
    }
}
