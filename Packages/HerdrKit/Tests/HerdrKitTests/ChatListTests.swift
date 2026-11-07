import Foundation
import Testing
@testable import HerdrKit

private func ws(_ id: String, _ n: Int, _ label: String) throws -> Workspace {
    try HerdrJSON.decoder.decode(Workspace.self, from: Data(#"{"workspace_id":"\#(id)","number":\#(n),"label":"\#(label)","focused":false,"pane_count":1,"tab_count":1,"agent_status":"idle"}"#.utf8))
}
private func tab(_ ws: String, _ n: Int = 1) throws -> Tab {
    try HerdrJSON.decoder.decode(Tab.self, from: Data(#"{"tab_id":"\#(ws):t\#(n)","workspace_id":"\#(ws)","number":\#(n),"label":"\#(n)","focused":false,"pane_count":1,"agent_status":"idle"}"#.utf8))
}
private func pane(_ id: String, cwd: String) throws -> Pane {
    let ws = String(id.split(separator: ":")[0])
    return try HerdrJSON.decoder.decode(Pane.self, from: Data(#"{"pane_id":"\#(id)","tab_id":"\#(ws):t1","workspace_id":"\#(ws)","cwd":"\#(cwd)","agent_status":"unknown"}"#.utf8))
}
private func agent(_ pane: String, kind: String, cwd: String) throws -> Agent {
    let ws = String(pane.split(separator: ":")[0])
    return try HerdrJSON.decoder.decode(Agent.self, from: Data(#"{"pane_id":"\#(pane)","workspace_id":"\#(ws)","tab_id":"\#(ws):t1","agent_status":"idle","agent":"\#(kind)","cwd":"\#(cwd)"}"#.utf8))
}

/// w2 (number 1, older) holds a claude agent and a shell; wA (number 2, newest) a codex agent; w9 a claude agent.
private func snapshot() throws -> HerdrSnapshot {
    HerdrSnapshot(
        workspaces: [try ws("wA", 2, "api"), try ws("w2", 1, "app"), try ws("w9", 3, "app2")],
        tabs: [try tab("w2"), try tab("wA"), try tab("w9")],
        panes: [try pane("w2:p1", cwd: "/home/u/app"), try pane("w2:p2", cwd: "/home/u/app"),
                try pane("wA:p1", cwd: "/home/u/api"), try pane("w9:p1", cwd: "/home/u/app")],
        agents: [try agent("w2:p1", kind: "claude", cwd: "/home/u/app"), try agent("wA:p1", kind: "codex", cwd: "/home/u/api"),
                 try agent("w9:p1", kind: "claude", cwd: "/home/u/app")])
}

private func ids(_ groups: [ChatGroup]) -> [[String]] { groups.map { $0.items.map(\.paneId) } }

@Suite struct ChatListTests {
    @Test func workspaceOrderKeepsShellsAndHerdrNumbering() throws {
        let g = try snapshot().chatGroups(.workspace)
        #expect(ids(g) == [["w2:p1", "w2:p2"], ["wA:p1"], ["w9:p1"]])
        #expect(g[0].title == "1 · app")
        #expect(g[0].items[1].agent == nil)
    }

    @Test func newestUsesCreationOrderOfIds() throws {
        #expect(ids(try snapshot().chatGroups(.newest)) == [["wA:p1", "w9:p1", "w2:p2", "w2:p1"]])
        #expect(ids(try snapshot().chatGroups(.oldest)) == [["w2:p1", "w2:p2", "w9:p1", "wA:p1"]])
        #expect(try snapshot().chatGroups(.newest)[0].title == nil)
    }

    @Test func groupsByFolder() throws {
        let g = try snapshot().chatGroups(.folder)
        #expect(g.map(\.title) == ["~/api", "~/app"])
        #expect(ids(g) == [["wA:p1"], ["w2:p1", "w2:p2", "w9:p1"]])
    }

    @Test func groupsByAgentKindWithTerminalsLast() throws {
        let g = try snapshot().chatGroups(.kind)
        #expect(g.map(\.title) == ["Claude Code", "Codex", "Terminals"])
        #expect(ids(g) == [["w2:p1", "w9:p1"], ["wA:p1"], ["w2:p2"]])
    }

    @Test func creationRankComparesIdsByLengthThenCharacters() {
        #expect(HerdrSnapshot.createdBefore("w9:p1", "wA:p1"))
        #expect(HerdrSnapshot.createdBefore("wZ:p9", "w10:p1"))
        #expect(HerdrSnapshot.createdBefore("w2:p2", "w2:p10"))
        #expect(!HerdrSnapshot.createdBefore("wA:p1", "w9:p1"))
    }
}

@Suite struct TranscriptMergeTests {
    let history: [TranscriptBlock] = [.user("eins"), .assistant([.prose("Antwort eins")]), .user("zwei"), .assistant([.prose("Teil")])]

    @Test func visibleScreenContinuesHistory() {
        let screen: [TranscriptBlock] = [.assistant([.prose("t eins")]), .user("zwei"), .assistant([.prose("Teil und mehr")]),
                                         .meta("Thinking… (3s)")]
        #expect(ClaudeTranscript.merge(history: history, screen: screen)
                == [.user("eins"), .assistant([.prose("Antwort eins")]), .user("zwei"), .assistant([.prose("Teil und mehr")]),
                    .meta("Thinking… (3s)")])
    }

    @Test func noOverlapAppendsScreen() {
        let screen: [TranscriptBlock] = [.user("drei")]
        #expect(ClaudeTranscript.merge(history: history, screen: screen) == history + screen)
    }

    @Test func emptySides() {
        #expect(ClaudeTranscript.merge(history: [], screen: [.user("a")]) == [.user("a")])
        #expect(ClaudeTranscript.merge(history: history, screen: []) == history)
    }

    @Test func metaAloneIsNoAnchor() {
        let h: [TranscriptBlock] = [.meta("Ran 1 shell command"), .user("a")]
        let screen: [TranscriptBlock] = [.meta("Ran 1 shell command"), .user("b")]
        #expect(ClaudeTranscript.merge(history: h, screen: screen) == h + screen)
    }

    @Test func spinnerIsActivity() {
        #expect(TranscriptBlock.meta("Thinking… (3s · esc to interrupt)").isActivity)
        #expect(!TranscriptBlock.meta("Crunched for 41s · done 6:25 PM").isActivity)
        #expect(!TranscriptBlock.user("Thinking…").isActivity)
    }
}
