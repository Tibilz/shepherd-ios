import Foundation
import Testing
import HerdrKit
@testable import HerdrSSH

/// Runs only with HERDR_IT_HOST, HERDR_IT_USER, HERDR_IT_KEY (path) set.
/// Uses the isolated herdr session HERDR_IT_SESSION (default "herdrapp-test"); never touches other sessions.
struct ITConfig {
    let host: String, user: String, pem: String, session: String
    static let current: ITConfig? = {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["HERDR_IT_HOST"], let user = env["HERDR_IT_USER"], let path = env["HERDR_IT_KEY"],
              let pem = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { return nil }
        return ITConfig(host: host, user: user, pem: pem, session: env["HERDR_IT_SESSION"] ?? "herdrapp-test")
    }()

    func connect() async throws -> CitadelShell {
        let kind = try SSHKeyImport.parse(pem, passphrase: nil).kind
        let profile = ServerProfile(name: "it", host: host, user: user, keyId: UUID(), session: session)
        return try await CitadelShell.connect(profile: profile, pem: pem, passphrase: nil, kind: kind) { _ in true }
    }
}

@Suite(.enabled(if: ITConfig.current != nil), .serialized)
struct VPSIntegrationTests {
    @Test func connectsAndReadsStatus() async throws {
        let shell = try await ITConfig.current!.connect()
        let client = HerdrClient(shell: shell, session: ITConfig.current!.session)
        let st = try await client.connect()
        #expect(st.protocolVersion == 22)
        #expect(st.socket.contains(ITConfig.current!.session))
        await shell.close()
    }

    @Test func execReportsExitCodeAndStderr() async throws {
        let shell = try await ITConfig.current!.connect()
        let r = try await shell.exec("echo out; echo err >&2; exit 3")
        #expect(String(decoding: r.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: r.stderr, as: UTF8.self) == "err\n")
        #expect(r.exitCode == 3)
        await shell.close()
    }

    @Test func listsWorkspaces() async throws {
        let shell = try await ITConfig.current!.connect()
        let client = HerdrClient(shell: shell, session: ITConfig.current!.session)
        try await client.connect()
        #expect(try await client.workspaces().count >= 1)
        await shell.close()
    }

    @Test func eventStreamStarts() async throws {
        let shell = try await ITConfig.current!.connect()
        let client = HerdrClient(shell: shell, session: ITConfig.current!.session)
        try await client.connect()
        let stream = try await client.eventStream()
        let first = try await withThrowingTaskGroup(of: HerdrEvent?.self) { g in
            g.addTask { for try await e in stream { return e }; return nil }
            g.addTask { try await Task.sleep(for: .seconds(5)); return nil }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
        #expect(first?.type == "subscription_started")
        await shell.close()
    }

    @Test func sendTextRoundTripInOwnWorkspace() async throws {
        let shell = try await ITConfig.current!.connect()
        let client = HerdrClient(shell: shell, session: ITConfig.current!.session)
        try await client.connect()
        let pane = try #require(try await client.panes().first)
        let marker = "herdrapp-it-\(Int.random(in: 1000...9999)) ä'\""
        try await client.runInPane(pane.paneId, command: "echo \(ShellQuote.quote(marker))")
        try await Task.sleep(for: .seconds(1))
        let read = try await client.readPane(pane.paneId, lines: 50)
        #expect(read.text.contains(marker))
        await shell.close()
    }

    @Test func ptyRunsCommand() async throws {
        let shell = try await ITConfig.current!.connect()
        let pty = try await shell.openPTY(command: "echo pty-ok; sleep 1", cols: 80, rows: 24)
        var got = ""
        for try await chunk in pty.output {
            got += String(decoding: chunk, as: UTF8.self)
            if got.contains("pty-ok") { break }
        }
        #expect(got.contains("pty-ok"))
        await pty.close()
        await shell.close()
    }

    /// Regression: status changes arrive only as per-pane `pane.agent_status_changed` events.
    @MainActor @Test func liveSessionSeesStatusChangeViaEvents() async throws {
        let c = ITConfig.current!
        let shell = try await c.connect()
        let client = HerdrClient(shell: shell, session: c.session)
        try await client.connect()
        let pane = try #require(try await client.panes().first).paneId
        let herdr = "herdr --session \(c.session)"
        _ = try await shell.exec(SocketCommand.login("\(herdr) pane report-agent --source it --agent claude --state working \(pane)"))
        let session = LiveSession(client: client, pollInterval: .seconds(60))
        await session.start()
        func status() -> AgentStatus? { session.snapshot?.agents.first { $0.paneId == pane }?.agentStatus }
        for _ in 0..<50 where !(session.state == .live && status() == .working) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(session.state == .live, "state: \(session.state)")
        #expect(status() == .working, "agents: \(session.snapshot?.agents.map { ($0.paneId, $0.agentStatus) } ?? [])")
        _ = try await shell.exec(SocketCommand.login("\(herdr) pane report-agent --source it --agent claude --state blocked \(pane)"))
        for _ in 0..<30 where status() != .blocked { try await Task.sleep(for: .milliseconds(100)) }
        #expect(status() == .blocked, "status change must arrive via events within 3 s (poll interval is 60 s)")
        session.stop()
        _ = try? await shell.exec(SocketCommand.login("\(herdr) pane release-agent --source it --agent claude \(pane)"))
        await shell.close()
    }

    @Test func untrustedHostKeyIsRejected() async throws {
        let c = ITConfig.current!
        let kind = try SSHKeyImport.parse(c.pem, passphrase: nil).kind
        let profile = ServerProfile(name: "it", host: c.host, user: c.user, keyId: UUID())
        await #expect(throws: HerdrError.self) {
            _ = try await CitadelShell.connect(profile: profile, pem: c.pem, passphrase: nil, kind: kind) { _ in false }
        }
    }
}
