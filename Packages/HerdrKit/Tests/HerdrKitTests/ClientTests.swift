import Foundation
import Testing
@testable import HerdrKit

func runningShell() throws -> FakeShell {
    let s = FakeShell()
    s.statusOutput = ExecResult(stdout: Data(try fixtureText("status_running").utf8), stderr: Data(), exitCode: 0)
    s.responses = [
        "workspace.list": String(decoding: try fixture("workspace_list"), as: UTF8.self),
        "tab.list": String(decoding: try fixture("tab_list"), as: UTF8.self),
        "pane.list": String(decoding: try fixture("pane_list"), as: UTF8.self),
        "agent.list": String(decoding: try fixture("agent_list"), as: UTF8.self),
        "agent.read": #"{"type":"agent_read","read":{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","source":"recent_unwrapped","format":"text","text":"hello","revision":4,"truncated":true}}"#,
    ]
    return s
}

@Suite struct ClientTests {
    @Test func statusParsingRunning() async throws {
        let client = HerdrClient(shell: try runningShell())
        let st = try await client.connect()
        #expect(st.socket == "/home/ubuntu/.config/herdr/sessions/herdrapp-test/herdr.sock")
        #expect(st.protocolVersion == 22)
        #expect(st.version == "0.9.5")
    }

    @Test func statusCommandUsesSessionAndLoginShell() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell, herdrPath: "/opt/herdr", session: "herdrapp-test")
        _ = try await client.connect()
        #expect(shell.commands.first == "bash -lc '/opt/herdr --session herdrapp-test status'")
    }

    @Test func statusParsingNotFound() async throws {
        let s = FakeShell()
        s.statusOutput = ExecResult(stdout: Data(), stderr: Data("bash: line 1: herdr: command not found".utf8), exitCode: 127)
        await #expect(throws: HerdrError.herdrNotFound) { try await HerdrClient(shell: s).connect() }
    }

    @Test func statusParsingStopped() async throws {
        let s = FakeShell()
        s.statusOutput = ExecResult(stdout: Data(try fixtureText("status_stopped").utf8), stderr: Data(), exitCode: 0)
        await #expect(throws: HerdrError.notRunning) { try await HerdrClient(shell: s).connect() }
    }

    @Test func statusProtocolMismatch() async throws {
        let s = FakeShell()
        let text = try fixtureText("status_running").replacingOccurrences(of: "private_protocol: 22", with: "private_protocol: 23")
        s.statusOutput = ExecResult(stdout: Data(text.utf8), stderr: Data(), exitCode: 0)
        await #expect(throws: HerdrError.protocolMismatch("0.9.5")) { try await HerdrClient(shell: s).connect() }
    }

    @Test func callsBeforeConnectFail() async throws {
        await #expect(throws: HerdrError.self) { try await HerdrClient(shell: try runningShell()).agents() }
    }

    @Test func snapshotCombinesLists() async throws {
        let client = HerdrClient(shell: try runningShell())
        _ = try await client.connect()
        let snap = try await client.snapshot()
        #expect(snap.workspaces.count == 2)
        #expect(snap.agents.count == 3)
        #expect(snap.panes.count == 3)
    }

    @Test func readAgentUsesLineLimit() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        let read = try await client.readAgent("reviewer")
        let p = try #require(shell.params(of: "agent.read"))
        #expect(p["lines"] as? Int == 400)
        #expect(p["source"] as? String == "recent_unwrapped")
        #expect(p["target"] as? String == "reviewer")
        #expect(read.text == "hello")
        #expect(read.truncated)
    }

    @Test func promptSendsExactText() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        let text = "Schreib Tests für 'login' $(rm -rf /)\nZeile 2 🚀"
        try await client.prompt("reviewer", text: text)
        let p = try #require(shell.params(of: "agent.prompt"))
        #expect(p["text"] as? String == text)
        #expect(p["target"] as? String == "reviewer")
        #expect(p["wait"] == nil)
    }

    @Test func promptIsNotRetried() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        let before = shell.commands.count
        shell.failNext = .transport("Verbindung verloren")
        await #expect(throws: HerdrError.transport("Verbindung verloren")) { try await client.prompt("reviewer", text: "x") }
        #expect(shell.commands.count == before + 1)
    }

    @Test func sendKeysAndRunInPane() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        try await client.sendKeys("reviewer", keys: ["esc", "ctrl+c"])
        #expect(shell.params(of: "agent.send_keys")?["keys"] as? [String] == ["esc", "ctrl+c"])
        try await client.runInPane("w1:p1", command: "ls -la")
        let p = try #require(shell.params(of: "pane.send_input"))
        #expect(p["pane_id"] as? String == "w1:p1")
        #expect(p["text"] as? String == "ls -la")
        #expect(p["keys"] as? [String] == ["enter"])
    }

    @Test func renamePaneSetsAndClearsLabel() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        try await client.renamePane("w1:p1", label: "  Mein Chat ä  ")
        #expect(shell.params(of: "pane.rename")?["label"] as? String == "Mein Chat ä")
        #expect(shell.params(of: "pane.rename")?["pane_id"] as? String == "w1:p1")
        try await client.renamePane("w1:p1", label: "   ")
        let p = try #require(shell.params(of: "pane.rename"))
        #expect(p.keys.contains("label") && p["label"] is NSNull)
    }

    @Test func serverErrorIsSurfaced() async throws {
        let shell = try runningShell()
        shell.errors["agent.focus"] = (code: "agent_not_found", message: "no agent named ghost")
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        await #expect(throws: HerdrError.server(code: "agent_not_found", message: "no agent named ghost")) {
            try await client.focusAgent("ghost")
        }
    }

    @Test func emptyOutputIsTransportError() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        shell.responses["agent.list"] = ""
        shell.emptyFor = "agent.list"
        await #expect(throws: HerdrError.notRunning) { try await client.agents() }
    }

    @Test func requestIdsIncrease() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        _ = try await client.workspaces()
        _ = try await client.agents()
        #expect(shell.requests.map { $0["id"] as? String } == ["app-1", "app-2"])
    }

    @Test func cancellationIsNotATransportError() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        shell.failWith = CancellationError()
        await #expect(throws: CancellationError.self) { try await client.agents() }
    }

    @Test func missingSocketMapsToNotRunning() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        shell.emptyFor = "agent.list"
        shell.emptyStderr = "nc: unix connect failed: No such file or directory"
        await #expect(throws: HerdrError.notRunning) { try await client.agents() }
        shell.emptyStderr = "nc: unix connect failed: Connection refused"
        await #expect(throws: HerdrError.notRunning) { try await client.agents() }
    }

    @Test func incompatibleNetcatGetsHint() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        shell.emptyFor = "agent.list"
        shell.emptyStderr = "nc: invalid option -- 'N'"
        await #expect(throws: HerdrError.netcatMissing) { try await client.agents() }
    }

    /// herdr 0.9.5: a blocked agent's alternate-screen history can't be read; the visible screen can.
    @Test func readAgentFallsBackToVisibleWhenNotIdle() async throws {
        let shell = try runningShell()
        shell.errorFilter = { method, params in
            method == "agent.read" && params["source"] as? String == "recent_unwrapped"
                ? ("agent_not_idle", "cannot read 400 lines while w5:p1 is blocked") : nil
        }
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        let read = try await client.readAgent("reviewer")
        #expect(read.text == "hello")
        let p = try #require(shell.params(of: "agent.read"))
        #expect(p["source"] as? String == "visible")
        #expect(p["lines"] == nil)
    }

    @Test func otherReadErrorsStillSurface() async throws {
        let shell = try runningShell()
        shell.errorFilter = { m, _ in m == "agent.read" ? ("agent_not_found", "no agent") : nil }
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        await #expect(throws: HerdrError.server(code: "agent_not_found", message: "no agent")) { _ = try await client.readAgent("x") }
    }
}
