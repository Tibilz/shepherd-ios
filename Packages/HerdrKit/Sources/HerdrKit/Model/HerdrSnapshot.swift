import Foundation

public struct HerdrSnapshot: Sendable, Equatable {
    public var workspaces: [Workspace]
    public var tabs: [Tab]
    public var panes: [Pane]
    public var agents: [Agent]

    public init(workspaces: [Workspace], tabs: [Tab], panes: [Pane], agents: [Agent]) {
        self.workspaces = workspaces.sorted { $0.number < $1.number }
        self.tabs = tabs
        self.panes = panes
        let labels = Dictionary(panes.compactMap { p in p.label.nonBlank.map { (p.paneId, $0) } }, uniquingKeysWith: { a, _ in a })
        self.agents = agents.map { a in var a = a; if a.label == nil { a.label = labels[a.paneId] }; return a }
    }

    public func tabs(in workspace: Workspace) -> [Tab] {
        tabs.filter { $0.workspaceId == workspace.workspaceId }.sorted { $0.number < $1.number }
    }

    public func panes(in tab: Tab) -> [Pane] {
        panes.filter { $0.tabId == tab.tabId }
    }

    public func agent(onPane paneId: String) -> Agent? {
        agents.first { $0.paneId == paneId }
    }

    /// Agents in the order the user sees them: workspace number, tab number, pane order.
    /// Agents whose workspace/tab/pane is not in the snapshot sort last, by pane id.
    public var orderedAgents: [Agent] {
        let wsRank = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceId, $0.number) })
        let tabRank = Dictionary(tabs.map { ($0.tabId, $0.number) }, uniquingKeysWith: { a, _ in a })
        let paneRank = Dictionary(panes.enumerated().map { ($1.paneId, $0) }, uniquingKeysWith: { a, _ in a })
        func key(_ a: Agent) -> (Int, Int, Int, String) {
            (wsRank[a.workspaceId] ?? .max, tabRank[a.tabId] ?? .max, paneRank[a.paneId] ?? .max, a.paneId)
        }
        return agents.sorted { key($0) < key($1) }
    }

    public var needsAttention: [Agent] {
        orderedAgents.filter { $0.agentStatus == .blocked || $0.agentStatus == .done }
    }
}
