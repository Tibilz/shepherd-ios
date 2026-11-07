import Foundation

/// How the server overview lists chats and terminals.
public enum ChatSort: String, CaseIterable, Sendable {
    case workspace, newest, oldest, folder, kind

    public var label: String {
        switch self {
        case .workspace: "Workspace"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .folder: "By Folder"
        case .kind: "By Agent"
        }
    }
}

/// One row: a pane, with its agent when one runs there.
public struct ChatItem: Sendable, Equatable, Identifiable {
    public var pane: Pane
    public var agent: Agent?
    public var id: String { pane.paneId }
    public var paneId: String { pane.paneId }
    /// Working directory (the agent's, else the shell's current one).
    public var cwd: String? { agent?.cwd ?? pane.foregroundCwd ?? pane.cwd }
    /// Name shown in lists: agent display name, pane label, terminal title, "Terminal".
    public var title: String {
        if let agent { return agent.displayName }
        return pane.label.nonBlank ?? pane.terminalTitleStripped.nonBlank ?? "Terminal"
    }
}

public struct ChatGroup: Sendable, Equatable, Identifiable {
    public var id: String
    /// nil for a flat list.
    public var title: String?
    public var status: AgentStatus?
    public var items: [ChatItem]
}

extension HerdrSnapshot {
    /// Ids aren't reused and grow with each new workspace/pane ("w9" < "wA" < "w10"), so they give creation order.
    static func creationKey(_ paneId: String) -> [Int] {
        func key(_ s: Substring) -> [Int] {
            let digits = s.dropFirst()   // "w", "t", "p"
            return [digits.count] + digits.unicodeScalars.map { Int($0.value) }
        }
        let parts = paneId.split(separator: ":")
        return parts.flatMap { key($0) + [-1] }
    }

    public static func createdBefore(_ a: String, _ b: String) -> Bool {
        creationKey(a).lexicographicallyPrecedes(creationKey(b))
    }

    public var chatItems: [ChatItem] {
        panes.map { p in ChatItem(pane: p, agent: agent(onPane: p.paneId)) }
    }

    /// Agents that are blocked or done, as rows (agents whose pane is missing from the snapshot are skipped).
    public var attentionItems: [ChatItem] {
        needsAttention.compactMap { a in panes.first { $0.paneId == a.paneId }.map { ChatItem(pane: $0, agent: a) } }
    }

    public func chatGroups(_ sort: ChatSort) -> [ChatGroup] {
        switch sort {
        case .workspace:
            return workspaces.map { ws in
                let items = tabs(in: ws).flatMap { panes(in: $0) }.map { ChatItem(pane: $0, agent: agent(onPane: $0.paneId)) }
                return ChatGroup(id: ws.workspaceId, title: "\(ws.number) · \(ws.label)", status: ws.agentStatus, items: items)
            }.filter { !$0.items.isEmpty }
        case .newest, .oldest:
            var items = chatItems.sorted { Self.createdBefore($0.paneId, $1.paneId) }
            if sort == .newest { items.reverse() }
            return items.isEmpty ? [] : [ChatGroup(id: "all", title: nil, status: nil, items: items)]
        case .folder:
            return grouped { Self.shortPath($0.cwd) ?? "Unknown Folder" }
        case .kind:
            let terminals = "Terminals"
            return grouped { item in
                guard let a = item.agent else { return terminals }
                let k = a.agent ?? a.displayAgent ?? ""
                return HerdrClient.agentKinds.first { $0.kind == k }?.label ?? a.kindLabel
            }.sorted { ($0.id == terminals ? 1 : 0, $0.id) < ($1.id == terminals ? 1 : 0, $1.id) }
        }
    }

    /// Groups sorted by title, items oldest first inside each.
    private func grouped(by key: (ChatItem) -> String) -> [ChatGroup] {
        let items = chatItems.sorted { Self.createdBefore($0.paneId, $1.paneId) }
        var order: [String] = []
        var groups: [String: [ChatItem]] = [:]
        for item in items {
            let k = key(item)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(item)
        }
        return order.sorted().map { ChatGroup(id: $0, title: $0, status: nil, items: groups[$0]!) }
    }

    /// "/home/me/app" → "~/app", "/root/x" → "~/x".
    public static func shortPath(_ path: String?) -> String? {
        path?.replacingOccurrences(of: #"^(/home/[^/]+|/root)(?=/|$)"#, with: "~", options: .regularExpression)
    }
}
