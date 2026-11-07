import Foundation

public enum ClaudeError: Error, Equatable, LocalizedError {
    case notInstalled, notLoggedIn, timeout, failed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Claude Code is not installed on the server (command “claude” not found)."
        case .notLoggedIn: "Claude Code is not logged in on the server. Run “claude” there once and sign in."
        case .timeout: "Claude did not answer in time (90 s)."
        case .failed(let m): "Claude failed: \(m)"
        }
    }
}

/// Uses Claude Code on the server (`claude -p`, the user's subscription) to interpret speech and summarise.
public struct ClaudeAssistant: Sendable {
    public let shell: RemoteShell
    public let claudePath: String
    /// Language for explanations, questions and summaries, e.g. "English" or "German".
    public let language: String
    public init(shell: RemoteShell, claudePath: String = "claude", language: String = "English") {
        self.shell = shell
        self.claudePath = claudePath
        self.language = language
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

    static let notUnderstood = VoiceIntent.unknown(question: "I didn't understand that. Can you say it differently?")

    public func interpret(_ transcript: String, context: VoiceContext, forceShell: Bool) async throws -> VoiceIntent {
        let prompt = Self.intentPrompt(transcript, context: context, forceShell: forceShell, language: language)
        guard let out = try await run(command(prompt: prompt, cwd: "/tmp", model: "haiku", tools: "\"\"", schema: Self.intentSchema)) else {
            return Self.notUnderstood
        }
        if out.isError == true {
            let msg = out.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return msg.isEmpty ? Self.notUnderstood : .unknown(question: "Claude meldet: \(msg)")
        }
        guard let s = out.structuredOutput else { return Self.notUnderstood }
        if forceShell && s.type != "shell" && s.type != "unknown" {
            return .unknown(question: "I couldn't find a matching command for that.")
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
                return .unknown(question: "Which agent should get the message?")
            }
            return t == context.currentAgent?.target ? .prompt(text: text) : .promptAgent(target: t, text: text)
        case "summarize_agent":
            guard let t = agentTarget(s.agent) else { return .unknown(question: "Which agent should I summarize?") }
            return .summarizeAgent(target: t)
        case "summarize_file":
            guard let p = s.path, !p.isEmpty else { return .unknown(question: "Which file do you mean?") }
            let abs = p.hasPrefix("/") ? p : ((context.cwd ?? "~") as NSString).appendingPathComponent(p)
            return .summarizeFile(path: abs)
        case "navigate":
            guard let spoken = s.agent, let t = LocalIntentParser.resolveAgent(LocalIntentParser.words(spoken), in: context.agents) else {
                return .unknown(question: "I couldn't find that agent.")
            }
            return .navigateAgent(target: t)
        default:
            return .unknown(question: s.question ?? "I didn't understand that. Can you say it differently?")
        }
    }

    static func intentPrompt(_ transcript: String, context: VoiceContext, forceShell: Bool, language: String = "English") -> String {
        var lines = [
            "Translate a spoken instruction (German or English) for an iPhone app that controls herdr agents (coding agents in terminals on a Linux server) into exactly one intent following the JSON schema.",
            "Types:",
            "- shell: a single bash command (field command) for the directory cwd. Prefer read-only commands; only change or delete things when explicitly asked. Field explanation: one short sentence in \(language) describing what the command does.",
            "- prompt_agent: a message to an agent (agent = name, text = the message, phrased the way the user would say it to the agent).",
            "- summarize_agent: summary of what an agent has done (agent).",
            "- summarize_file: summary of a file (path, absolute or relative to cwd).",
            "- navigate: switch to an agent (agent).",
            "- unknown: unclear; question = a short clarifying question in \(language).",
            "Context:",
            "Directory (cwd): \(context.cwd ?? "~")",
        ]
        if context.agents.isEmpty {
            lines.append("Agents: none")
        } else {
            lines.append("Agents (position. name – status – directory):")
            for (i, a) in context.agents.enumerated() {
                lines.append("\(i + 1). \(a.target) – \(a.agentStatus.rawValue) – \(a.cwd ?? "?")")
            }
        }
        if let c = context.currentAgent { lines.append("Currently open agent: \(c.target)") }
        if forceShell { lines.append("The user explicitly wants a command: answer only with type \"shell\" (or unknown).") }
        lines.append("Instruction: \(transcript)")
        return lines.joined(separator: "\n")
    }

    public func summarize(agentOutput: String, agentName: String) async throws -> String {
        let prompt = """
        Summarize in \(language), in 3–6 short sentences, what the coding agent "\(agentName)" did most recently, \
        what the result is and whether it is waiting for something right now. Easy to read aloud, no Markdown, no code blocks.

        The agent's terminal output:
        \(Self.tail(agentOutput, maxBytes: 80_000))
        """
        return try await text(command(prompt: prompt, cwd: "/tmp", model: "sonnet", tools: "\"\"", schema: nil))
    }

    public func summarize(file path: String) async throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let prompt = "Read the file \"\(name)\" in this directory and summarize it in \(language) in 3–6 short sentences that are easy to read aloud, without Markdown."
        return try await text(command(prompt: prompt, cwd: dir.isEmpty ? "/" : dir, model: "sonnet", tools: "Read", schema: nil))
    }

    func text(_ cmd: String) async throws -> String {
        guard let out = try await run(cmd) else { throw ClaudeError.failed("no answer") }
        let r = out.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if out.isError == true { throw ClaudeError.failed(r.isEmpty ? "unknown error" : r) }
        guard !r.isEmpty else { throw ClaudeError.failed("no answer") }
        return r
    }

    /// Last `maxBytes` UTF-8 bytes (the prompt travels as one shell argument; Linux caps those at 128 KiB).
    static func tail(_ s: String, maxBytes: Int) -> String {
        let u = Array(s.utf8)
        guard u.count > maxBytes else { return s }
        return String(decoding: u.suffix(maxBytes), as: UTF8.self)
    }
}
