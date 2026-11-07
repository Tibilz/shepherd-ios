import Foundation

public struct CreatedWorkspace: Sendable, Equatable {
    public let workspaceId: String
    public let rootPaneId: String
}

extension HerdrClient {
    /// Agent kinds herdr 0.9.5 can start (`herdr agent start --kind`), most common first.
    public static let agentKinds: [(kind: String, label: String)] = [
        ("claude", "Claude Code"), ("codex", "Codex"), ("gemini", "Gemini CLI"), ("opencode", "OpenCode"),
        ("cursor", "Cursor"), ("copilot", "Copilot CLI"), ("amp", "Amp"), ("droid", "Droid"), ("qwen", "Qwen Code"),
        ("kimi", "Kimi"), ("grok", "Grok"), ("cline", "Cline"), ("kiro", "Kiro"), ("devin", "Devin"), ("pi", "Pi"),
    ]

    private struct WorkspaceCreated: Decodable {
        struct W: Decodable { let workspaceId: String }
        struct P: Decodable { let paneId: String }
        let workspace: W
        let rootPane: P
    }

    public func createWorkspace(cwd: String, label: String, focus: Bool) async throws -> CreatedWorkspace {
        let r = try await call("workspace.create", ["cwd": .string(cwd), "label": .string(label), "focus": .bool(focus)],
                               as: WorkspaceCreated.self)
        return CreatedWorkspace(workspaceId: r.workspace.workspaceId, rootPaneId: r.rootPane.paneId)
    }

    private struct Started: Decodable { let type: String? }

    /// Starts an agent in an available shell pane. Agents that open a dialog right away (Claude Code's
    /// folder-trust question) make herdr answer `agent_not_ready`; they are running, so that counts as started.
    public func startAgent(name: String, kind: String, paneId: String, timeoutMs: Int = 60000) async throws {
        do {
            _ = try await call("agent.start", ["name": .string(name), "kind": .string(kind), "pane_id": .string(paneId),
                                               "timeout_ms": .int(timeoutMs)], as: Started.self)
        } catch HerdrError.server(code: "agent_not_ready", message: _) {}
    }

    /// A unique herdr agent name (`[a-z][a-z0-9_-]{0,31}`) derived from the folder name.
    public static func agentName(for folder: String, existing: Set<String>) -> String {
        var s = (folder as NSString).lastPathComponent.lowercased()
        for (a, b) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { s = s.replacingOccurrences(of: a, with: b) }
        s = s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        for ch in s {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") { out.append(ch) }
            else if out.last != "-" { out.append("-") }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.isEmpty || out == "/" { out = "agent" }
        if let f = out.first, !f.isLetter { out = "a-" + out }
        out = String(out.prefix(32))
        guard existing.contains(out) else { return out }
        var n = 2
        while true {
            let suffix = "-\(n)"
            let candidate = String(out.prefix(32 - suffix.count)) + suffix
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }
}

public enum LaunchError: Error, Equatable, LocalizedError {
    case notInstalled(kind: String, label: String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled(let kind, let label):
            "\(label) is not installed on the server (program “\(kind)” not found). Install it there first."
        }
    }
}

extension HerdrClient {
    /// herdr starts the kind's canonical executable, which is named like the kind.
    public func ensureInstalled(kind: String) async throws {
        let res = try await shell.exec(SocketCommand.login("command -v \(ShellQuote.quote(kind))"))
        guard res.exitCode == 0 else {
            let label = Self.agentKinds.first { $0.kind == kind }?.label ?? kind
            throw LaunchError.notInstalled(kind: kind, label: label)
        }
    }
}
