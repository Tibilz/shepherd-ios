import Foundation

public enum HerdrJSON {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

public enum AgentStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case idle, working, blocked, done, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

public struct Workspace: Codable, Sendable, Identifiable, Equatable {
    public var workspaceId: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var paneCount: Int
    public var tabCount: Int
    public var activeTabId: String?
    public var agentStatus: AgentStatus
    public var id: String { workspaceId }
}

public struct Tab: Codable, Sendable, Identifiable, Equatable {
    public var tabId: String
    public var workspaceId: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var paneCount: Int
    public var agentStatus: AgentStatus
    public var id: String { tabId }
}

public struct Pane: Codable, Sendable, Identifiable, Equatable {
    public var paneId: String
    public var tabId: String
    public var workspaceId: String
    public var terminalId: String
    public var cwd: String?
    public var foregroundCwd: String?
    public var focused: Bool
    public var agentStatus: AgentStatus
    public var terminalTitleStripped: String?
    /// Free-text label set with `pane.rename` (shown in herdr's desktop UI too).
    public var label: String?
    public var revision: Int
    public var id: String { paneId }
}

public struct Agent: Codable, Sendable, Identifiable, Equatable {
    public var paneId: String
    public var workspaceId: String
    public var tabId: String
    public var terminalId: String
    public var agentStatus: AgentStatus
    public var focused: Bool
    public var name: String?
    public var agent: String?
    public var displayAgent: String?
    public var title: String?
    public var cwd: String?
    public var interactiveReady: Bool
    public var revision: Int
    /// The agent's own window title, e.g. Claude's chat summary.
    public var terminalTitleStripped: String?
    /// The pane's label (copied in by `HerdrSnapshot`; `agent.list` doesn't carry it).
    public var label: String?
    public var id: String { paneId }

    /// The handle herdr accepts for agent commands: the live name, else the pane id.
    public var target: String { name ?? paneId }
    /// What the user calls this chat: own label, herdr name, the agent's chat title, else its kind.
    public var displayName: String { label.nonBlank ?? name ?? chatTitle ?? kindLabel }
    /// "claude", "codex", … (falls back to the pane id).
    public var kindLabel: String { displayAgent ?? agent ?? paneId }

    /// The terminal title when it describes the chat, not a shell prompt like `user@host: ~`.
    public var chatTitle: String? {
        guard let t = terminalTitleStripped.nonBlank else { return nil }
        if t.range(of: #"^\S+@\S+:"#, options: .regularExpression) != nil { return nil }
        if t.lowercased() == (agent ?? "").lowercased() { return nil }
        return t
    }
}

extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let t = self?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// herdr omits many fields depending on how an agent was detected/reported (e.g. no
// `interactive_ready` for reported agents). Only ids and status are required.
extension Agent {
    enum CodingKeys: String, CodingKey {
        case paneId, workspaceId, tabId, terminalId, agentStatus, focused, name, agent, displayAgent, title, cwd, interactiveReady, revision, terminalTitleStripped, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try c.decode(String.self, forKey: .paneId)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        tabId = try c.decode(String.self, forKey: .tabId)
        terminalId = try c.decodeIfPresent(String.self, forKey: .terminalId) ?? ""
        agentStatus = try c.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        displayAgent = try c.decodeIfPresent(String.self, forKey: .displayAgent)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        interactiveReady = try c.decodeIfPresent(Bool.self, forKey: .interactiveReady) ?? false
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        terminalTitleStripped = try c.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}

extension Pane {
    enum CodingKeys: String, CodingKey {
        case paneId, tabId, workspaceId, terminalId, cwd, foregroundCwd, focused, agentStatus, terminalTitleStripped, label, revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try c.decode(String.self, forKey: .paneId)
        tabId = try c.decode(String.self, forKey: .tabId)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        terminalId = try c.decodeIfPresent(String.self, forKey: .terminalId) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        foregroundCwd = try c.decodeIfPresent(String.self, forKey: .foregroundCwd)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        agentStatus = try c.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
        terminalTitleStripped = try c.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }
}
