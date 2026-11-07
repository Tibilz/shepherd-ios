import Foundation

public enum ClaudeError: Error, Equatable, LocalizedError {
    case notInstalled, notLoggedIn, timeout, failed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Claude Code ist auf dem Server nicht installiert (Befehl „claude“ nicht gefunden)."
        case .notLoggedIn: "Claude Code ist auf dem Server nicht angemeldet. Starte dort einmal „claude“ und melde dich an."
        case .timeout: "Claude hat nicht rechtzeitig geantwortet (90 s)."
        case .failed(let m): "Claude ist fehlgeschlagen: \(m)"
        }
    }
}

/// Uses Claude Code on the server (`claude -p`, the user's subscription) to interpret speech and summarise.
public struct ClaudeAssistant: Sendable {
    public let shell: RemoteShell
    public let claudePath: String
    public init(shell: RemoteShell, claudePath: String = "claude") {
        self.shell = shell
        self.claudePath = claudePath
    }

    static let intentSchema = #"""
    {"type":"object","properties":{"type":{"type":"string","enum":["shell","prompt_agent","summarize_agent","summarize_file","navigate","unknown"]},"command":{"type":"string"},"cwd":{"type":"string"},"agent":{"type":"string"},"text":{"type":"string"},"path":{"type":"string"},"explanation":{"type":"string"},"question":{"type":"string"}},"required":["type"]}
    """#

    /// The prompt goes in via stdin (base64 in the command), so spoken text never touches the shell.
    func command(prompt: String, cwd: String, model: String, tools: String, schema: String?) -> String {
        var c = ShellRun.cdPrefix(cwd) + "printf %s \(Data(prompt.utf8).base64EncodedString()) | base64 -d | timeout 90 "
        c += "\(claudePath) -p --model \(model) --tools \(tools) --no-session-persistence --setting-sources \"\" --strict-mcp-config"
        if let schema { c += " --json-schema \(ShellQuote.quote(schema))" }
        c += " --output-format json"
        return SocketCommand.login(c)
    }

    struct Output: Decodable {
        let isError: Bool?
        let result: String?
        let structuredOutput: Structured?
    }

    struct Structured: Decodable {
        let type: String
        let command: String?
        let cwd: String?
        let agent: String?
        let text: String?
        let path: String?
        let explanation: String?
        let question: String?
    }

    func run(_ cmd: String) async throws -> Output? {
        let res = try await shell.exec(cmd)
        let err = String(decoding: res.stderr, as: UTF8.self)
        let outText = String(decoding: res.stdout, as: UTF8.self)
        if res.exitCode == 127 || err.contains("command not found") { throw ClaudeError.notInstalled }
        // Only stderr / error results can mean "not logged in"; an answer may legitimately mention /login.
        func loginProblem(_ t: String) -> Bool {
            let l = t.lowercased()
            return l.contains("/login") || l.contains("invalid api key") || l.contains("not logged in") || l.contains("please run /login")
        }
        if loginProblem(err) { throw ClaudeError.notLoggedIn }
        if res.exitCode == 124 { throw ClaudeError.timeout }
        if res.exitCode != 0 && res.stdout.isEmpty {
            throw ClaudeError.failed(err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Exit-Code \(res.exitCode)" : err)
        }
        // Login shells may print banners first: decode the last JSON line.
        let line = outText.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? outText
        let out = try? HerdrJSON.decoder.decode(Output.self, from: Data(line.utf8))
        if out?.isError == true, loginProblem(out?.result ?? "") { throw ClaudeError.notLoggedIn }
        return out
    }

    static let notUnderstood = VoiceIntent.unknown(question: "Das habe ich nicht verstanden. Kannst du es anders sagen?")

    public func interpret(_ transcript: String, context: VoiceContext, forceShell: Bool) async throws -> VoiceIntent {
        let prompt = Self.intentPrompt(transcript, context: context, forceShell: forceShell)
        guard let out = try await run(command(prompt: prompt, cwd: "/tmp", model: "haiku", tools: "\"\"", schema: Self.intentSchema)) else {
            return Self.notUnderstood
        }
        if out.isError == true {
            let msg = out.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return msg.isEmpty ? Self.notUnderstood : .unknown(question: "Claude meldet: \(msg)")
        }
        guard let s = out.structuredOutput else { return Self.notUnderstood }
        if forceShell && s.type != "shell" && s.type != "unknown" {
            return .unknown(question: "Dafür habe ich keinen passenden Befehl gefunden.")
        }
        func agentTarget(_ spoken: String?) -> String? {
            guard let spoken, !spoken.isEmpty else { return context.currentAgent?.target }
            return LocalIntentParser.resolveAgent(LocalIntentParser.words(spoken), in: context.agents)
        }
        switch s.type {
        case "shell":
            guard let cmd = s.command?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty else { return Self.notUnderstood }
            return .shell(command: cmd, explanation: s.explanation ?? "", cwd: s.cwd ?? context.cwd)
        case "prompt_agent":
            guard let t = agentTarget(s.agent), let text = s.text, !text.isEmpty else {
                return .unknown(question: "An welchen Agent soll die Nachricht gehen?")
            }
            return t == context.currentAgent?.target ? .prompt(text: text) : .promptAgent(target: t, text: text)
        case "summarize_agent":
            guard let t = agentTarget(s.agent) else { return .unknown(question: "Welchen Agent soll ich zusammenfassen?") }
            return .summarizeAgent(target: t)
        case "summarize_file":
            guard let p = s.path, !p.isEmpty else { return .unknown(question: "Welche Datei meinst du?") }
            let abs = p.hasPrefix("/") ? p : ((context.cwd ?? "~") as NSString).appendingPathComponent(p)
            return .summarizeFile(path: abs)
        case "navigate":
            guard let spoken = s.agent, let t = LocalIntentParser.resolveAgent(LocalIntentParser.words(spoken), in: context.agents) else {
                return .unknown(question: "Diesen Agent habe ich nicht gefunden.")
            }
            return .navigateAgent(target: t)
        default:
            return .unknown(question: s.question ?? "Das habe ich nicht verstanden. Kannst du es anders sagen?")
        }
    }

    static func intentPrompt(_ transcript: String, context: VoiceContext, forceShell: Bool) -> String {
        var lines = [
            "Du übersetzt eine gesprochene Anweisung (deutsch oder englisch) für eine iPhone-App, die herdr-Agents (Coding-Agents in Terminals auf einem Linux-Server) steuert, in genau eine Absicht nach dem JSON-Schema.",
            "Typen:",
            "- shell: ein einzelner bash-Befehl (Feld command) für das Verzeichnis cwd. Bevorzuge lesende Befehle; verändernde oder löschende nur, wenn ausdrücklich verlangt. Feld explanation: ein kurzer deutscher Satz, was der Befehl tut.",
            "- prompt_agent: Nachricht an einen Agent (agent = Name, text = die Nachricht, so formuliert, wie der Nutzer sie dem Agent sagen würde).",
            "- summarize_agent: Zusammenfassung dessen, was ein Agent getan hat (agent).",
            "- summarize_file: Zusammenfassung einer Datei (path, absolut oder relativ zu cwd).",
            "- navigate: zu einem Agent wechseln (agent).",
            "- unknown: unklar; question = kurze Rückfrage auf Deutsch.",
            "Kontext:",
            "Verzeichnis (cwd): \(context.cwd ?? "~")",
        ]
        if context.agents.isEmpty {
            lines.append("Agents: keine")
        } else {
            lines.append("Agents (Position. Name – Status – Verzeichnis):")
            for (i, a) in context.agents.enumerated() {
                lines.append("\(i + 1). \(a.target) – \(a.agentStatus.rawValue) – \(a.cwd ?? "?")")
            }
        }
        if let c = context.currentAgent { lines.append("Gerade geöffneter Agent: \(c.target)") }
        if forceShell { lines.append("Der Nutzer will ausdrücklich einen Befehl: antworte nur den Typ „shell“ (oder unknown).") }
        lines.append("Anweisung: \(transcript)")
        return lines.joined(separator: "\n")
    }

    public func summarize(agentOutput: String, agentName: String) async throws -> String {
        let prompt = """
        Fasse auf Deutsch in 3–6 kurzen Sätzen zusammen, was der Coding-Agent „\(agentName)“ zuletzt getan hat, \
        was das Ergebnis ist und ob er gerade auf etwas wartet. Gut vorlesbar, ohne Markdown, ohne Code-Blöcke.

        Terminal-Ausgabe des Agents:
        \(Self.tail(agentOutput, maxBytes: 80_000))
        """
        return try await text(command(prompt: prompt, cwd: "/tmp", model: "sonnet", tools: "\"\"", schema: nil))
    }

    public func summarize(file path: String) async throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let prompt = "Lies die Datei „\(name)“ in diesem Verzeichnis und fasse sie auf Deutsch in 3–6 kurzen, gut vorlesbaren Sätzen zusammen, ohne Markdown."
        return try await text(command(prompt: prompt, cwd: dir.isEmpty ? "/" : dir, model: "sonnet", tools: "Read", schema: nil))
    }

    func text(_ cmd: String) async throws -> String {
        guard let out = try await run(cmd) else { throw ClaudeError.failed("keine Antwort") }
        let r = out.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if out.isError == true { throw ClaudeError.failed(r.isEmpty ? "unbekannter Fehler" : r) }
        guard !r.isEmpty else { throw ClaudeError.failed("keine Antwort") }
        return r
    }

    /// Last `maxBytes` UTF-8 bytes (the prompt travels as one shell argument; Linux caps those at 128 KiB).
    static func tail(_ s: String, maxBytes: Int) -> String {
        let u = Array(s.utf8)
        guard u.count > maxBytes else { return s }
        return String(decoding: u.suffix(maxBytes), as: UTF8.self)
    }
}
