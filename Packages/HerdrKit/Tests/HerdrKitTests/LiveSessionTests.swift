import Foundation
import Testing
@testable import HerdrKit

private func lines(_ s: String) -> Data { Data(s.utf8) }

@Suite struct EventLinesTests {
    @Test func splitterHandlesPartialLines() {
        var sp = LineSplitter()
        #expect(sp.feed(lines("{\"a\":1}\n{\"b\"")) == [lines("{\"a\":1}")])
        #expect(sp.feed(lines(":2}\n\n{\"c\":3}\n")) == [lines("{\"b\":2}"), lines("{\"c\":3}")])
        #expect(sp.feed(lines("")) == [])
    }

    @Test func parsesRealEvents() throws {
        let all = try fixtureText("events_stream").split(separator: "\n").map { Data($0.utf8) }
        let started = try HerdrEvent.parse(all[0])
        #expect(started.type == "subscription_started")
        let upd = try HerdrEvent.parse(all[1])
        #expect(upd.type == "pane_updated")
        #expect(upd.paneId == "w1:p1")
        #expect(upd.workspaceId == "w1")
        #expect(upd.agentStatus == .unknown)
        let ws = try HerdrEvent.parse(all[2])
        #expect(ws.type == "workspace_created")
        #expect(ws.workspaceId == "w1")
    }

    @Test func errorLineThrows() {
        #expect(throws: HerdrError.server(code: "invalid_request", message: "bad")) {
            _ = try HerdrEvent.parse(lines(#"{"id":"x","error":{"code":"invalid_request","message":"bad"}}"#))
        }
    }

    @Test func subscribeRequestUsesDottedTypes() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        _ = try await client.eventStream(types: ["pane.updated", "workspace.created"])
        let cmd = try #require(shell.commands.last)
        #expect(cmd.contains("exec timeout"))
        let req = try decodeEmbeddedRequest(cmd)
        #expect(req["method"] as? String == "events.subscribe")
        let subs = try #require((req["params"] as? [String: Any])?["subscriptions"] as? [[String: Any]])
        #expect(subs.map { $0["type"] as? String } == ["pane.updated", "workspace.created"])
    }
}

/// Polls `condition` until true or `timeout` passes. Avoids fixed sleeps that flake under load.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite struct LiveSessionTests {
    let started = #"{"id":"app-1","result":{"type":"subscription_started"}}"# + "\n"
    let event = #"{"data":{"type":"pane_updated","pane":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"working"}},"event":"pane_updated"}"# + "\n"

    func make(_ shell: FakeShell, debounce: Duration = .milliseconds(50), liveTimeout: Duration = .milliseconds(200)) -> LiveSession {
        LiveSession(client: HerdrClient(shell: shell), pollInterval: .milliseconds(50),
                    debounce: debounce, liveTimeout: liveTimeout)
    }

    @Test func subscriptionStartedGoesLive() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started)]
        shell.streamHangs = true
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { s.state == .live })
        #expect(s.snapshot?.agents.count == 3)
        s.stop()
    }

    @Test func eventsTriggerDebouncedRefresh() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started + event + event + event), lines(event + event)]
        shell.streamHangs = true
        // Generous debounce/timeout so all five events land inside one debounce window even under load.
        let s = make(shell, debounce: .milliseconds(500), liveTimeout: .seconds(5))
        await s.start()
        #expect(await waitUntil { shell.count(method: "agent.list") >= 2 })
        try await Task.sleep(for: .milliseconds(600))
        #expect(shell.count(method: "agent.list") == 2)
        #expect(s.state == .live)
        s.stop()
    }

    @Test func streamFailureFallsBackToPolling() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started)]
        shell.streamError = HerdrError.transport("weg")
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { s.state == .polling && shell.count(method: "agent.list") >= 3 })
        s.stop()
    }

    @Test func missingSubscriptionStartFallsBackToPolling() async throws {
        let shell = try runningShell()
        shell.streamHangs = true
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { s.state == .polling })
        s.stop()
    }

    @Test func connectFailureIsReported() async throws {
        let shell = FakeShell()
        shell.statusOutput = ExecResult(stdout: Data(try fixtureText("status_stopped").utf8), stderr: Data(), exitCode: 0)
        let s = make(shell)
        await s.start()
        #expect(s.state == .failed(HerdrError.notRunning.localizedDescription))
    }

    @Test func stopCancelsEverything() async throws {
        let shell = try runningShell()
        shell.streamError = HerdrError.transport("weg")
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { shell.count(method: "agent.list") >= 2 })
        s.stop()
        let n = shell.count(method: "agent.list")
        try await Task.sleep(for: .milliseconds(200))
        #expect(shell.count(method: "agent.list") == n)
        #expect(s.state == .idle)
    }

    @Test func refreshFailureThenSuccessRestoresLive() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started)]
        shell.streamHangs = true
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { s.state == .live })
        shell.failNext = .transport("kurz weg")
        await s.refresh()
        #expect(s.state == .failed(HerdrError.transport("kurz weg").localizedDescription))
        await s.refresh()
        #expect(s.state == .live)
        s.stop()
    }

    @Test func ensureRunningRestartsFailedSession() async throws {
        let shell = FakeShell()
        shell.statusOutput = ExecResult(stdout: Data(try fixtureText("status_stopped").utf8), stderr: Data(), exitCode: 0)
        let s = make(shell)
        await s.start()
        #expect(s.state == .failed(HerdrError.notRunning.localizedDescription))
        shell.statusOutput = ExecResult(stdout: Data(try fixtureText("status_running").utf8), stderr: Data(), exitCode: 0)
        shell.responses = try runningShell().responses
        shell.streamChunks = [lines(started)]
        shell.streamHangs = true
        await s.ensureRunning()
        #expect(await waitUntil { s.state == .live })
        #expect(s.snapshot != nil)
        s.stop()
    }

    @Test func ensureRunningRestartsStoppedSession() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started)]
        shell.streamHangs = true
        let s = make(shell)
        await s.start()
        s.stop()
        #expect(s.state == .idle)
        await s.ensureRunning()
        #expect(await waitUntil { s.state == .live })
        s.stop()
    }

    @Test func ensureRunningLeavesLiveSessionAlone() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started)]
        shell.streamHangs = true
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { s.state == .live })
        let before = shell.commands.count
        await s.ensureRunning()
        #expect(shell.commands.count == before)
        s.stop()
    }

    func subscriptions(in command: String) throws -> [[String: Any]] {
        let req = try decodeEmbeddedRequest(command)
        return try #require((req["params"] as? [String: Any])?["subscriptions"] as? [[String: Any]])
    }

    @Test func subscribesToStatusChangesOfEveryAgentPane() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started)]
        shell.streamHangs = true
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { s.state == .live })
        let cmd = try #require(shell.commands.last { $0.contains("exec timeout") })
        let panes = try subscriptions(in: cmd).filter { $0["type"] as? String == "pane.agent_status_changed" }.compactMap { $0["pane_id"] as? String }
        #expect(Set(panes) == ["w1:p2", "w2:p1", "w3:p1"])
        s.stop()
    }

    @Test func resubscribesWhenAgentPanesChange() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started)]
        shell.streamHangs = true
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { s.state == .live })
        let before = shell.commands.filter { $0.contains("exec timeout") }.count
        shell.responses["agent.list"] = #"{"type":"agent_list","agents":[{"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","terminal_id":"t","agent_status":"idle","focused":false,"interactive_ready":true,"revision":1}]}"#
        await s.refresh()
        #expect(await waitUntil { shell.commands.filter { $0.contains("exec timeout") }.count == before + 1 })
        let cmd = try #require(shell.commands.last { $0.contains("exec timeout") })
        #expect(try subscriptions(in: cmd).contains { $0["pane_id"] as? String == "w9:p1" })
        #expect(await waitUntil { s.state == .live })
        s.stop()
    }

    @Test func unchangedAgentPanesDoNotResubscribe() async throws {
        let shell = try runningShell()
        shell.streamChunks = [lines(started)]
        shell.streamHangs = true
        let s = make(shell)
        await s.start()
        #expect(await waitUntil { s.state == .live })
        let before = shell.commands.filter { $0.contains("exec timeout") }.count
        await s.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(shell.commands.filter { $0.contains("exec timeout") }.count == before)
        s.stop()
    }
}
