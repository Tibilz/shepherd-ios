import Foundation
import Testing
@testable import HerdrKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private struct WorkspaceListResult: Decodable { let workspaces: [Workspace] }
private struct TabListResult: Decodable { let tabs: [Tab] }
private struct PaneListResult: Decodable { let panes: [Pane] }
private struct AgentListResult: Decodable { let agents: [Agent] }

func fixtureSnapshot() throws -> HerdrSnapshot {
    let d = HerdrJSON.decoder
    return HerdrSnapshot(
        workspaces: try d.decode(WorkspaceListResult.self, from: fixture("workspace_list")).workspaces,
        tabs: try d.decode(TabListResult.self, from: fixture("tab_list")).tabs,
        panes: try d.decode(PaneListResult.self, from: fixture("pane_list")).panes,
        agents: try d.decode(AgentListResult.self, from: fixture("agent_list")).agents
    )
}

@Suite struct ModelTests {
    @Test func decodesRealWorkspaceList() throws {
        let ws = try HerdrJSON.decoder.decode(WorkspaceListResult.self, from: fixture("workspace_list")).workspaces
        #expect(ws.count == 2)
        #expect(ws[0].label == "~")
        #expect(ws[0].paneCount == 1)
        #expect(ws[0].agentStatus == .unknown)
        #expect(ws[0].id == "w1")
        #expect(ws[1].agentStatus == .working)
    }

    @Test func decodesPanesWithMissingOptionals() throws {
        let panes = try HerdrJSON.decoder.decode(PaneListResult.self, from: fixture("pane_list")).panes
        #expect(panes.count == 3)
        #expect(panes[0].terminalTitleStripped == "ubuntu@myhost: ~")
        #expect(panes[2].terminalTitleStripped == nil)
    }

    @Test func decodesAgents() throws {
        let agents = try HerdrJSON.decoder.decode(AgentListResult.self, from: fixture("agent_list")).agents
        #expect(agents.count == 3)
        let reviewer = try #require(agents.first { $0.name == "reviewer" })
        #expect(reviewer.agentStatus == .blocked)
        #expect(reviewer.displayName == "reviewer")
        #expect(agents[0].displayName == "Codex")
    }

    @Test func unknownStatusFallsBack() throws {
        let agents = try HerdrJSON.decoder.decode(AgentListResult.self, from: fixture("agent_list")).agents
        #expect(agents[2].agentStatus == .unknown)
    }

    @Test func orderedAgentsSortByWorkspaceThenTabThenPane() throws {
        let snap = try fixtureSnapshot()
        #expect(snap.orderedAgents.map(\.paneId) == ["w1:p2", "w2:p1", "w3:p1"])
    }

    @Test func needsAttentionContainsBlockedAndDone() throws {
        let snap = try fixtureSnapshot()
        #expect(snap.needsAttention.map(\.paneId) == ["w1:p2"])
    }

    @Test func treeNavigation() throws {
        let snap = try fixtureSnapshot()
        let w1 = try #require(snap.workspaces.first)
        let tabs = snap.tabs(in: w1)
        #expect(tabs.map(\.tabId) == ["w1:t1"])
        #expect(snap.panes(in: tabs[0]).map(\.paneId) == ["w1:p1", "w1:p2"])
        #expect(snap.agent(onPane: "w1:p2")?.name == "reviewer")
        #expect(snap.agent(onPane: "w1:p1") == nil)
    }
}

@Suite struct RealAgentListTests {
    private struct AgentListResult: Decodable { let agents: [Agent] }

    /// Captured from herdr 0.9.5 on Testserver (agent reported via `pane report-agent`): no interactive_ready etc.
    @Test func decodesRealAgentListWithoutOptionalFields() throws {
        let agents = try HerdrJSON.decoder.decode(AgentListResult.self, from: fixture("agent_list_real")).agents
        #expect(agents.count == 1)
        #expect(agents[0].paneId == "w1:p1")
        #expect(agents[0].agentStatus == .working)
        #expect(agents[0].displayName == "claude")
        #expect(agents[0].interactiveReady == false)
    }

    @Test func decodesMinimalAgent() throws {
        let json = #"{"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"t","agent_status":"idle"}]}"#
        let a = try HerdrJSON.decoder.decode(AgentListResult.self, from: Data(json.utf8)).agents[0]
        #expect(a.focused == false)
        #expect(a.revision == 0)
    }
}
