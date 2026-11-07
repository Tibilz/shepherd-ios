import Foundation
import Testing
import HerdrKit
@testable import HerdrSSH

@Suite(.enabled(if: ITConfig.current != nil), .serialized)
struct LaunchIntegrationTests {
    @Test func listsHomeAndSubfolder() async throws {
        let shell = try await ITConfig.current!.connect()
        let files = RemoteFiles(shell: shell)
        let home = try await files.list(nil)
        #expect(home.path.hasPrefix("/"))
        #expect(home.entries.contains { $0.name == ".config" && $0.isDirectory })
        let sub = try await files.list(home.path + "/.config")
        #expect(sub.entries.contains { $0.name == "herdr" && $0.isDirectory })
        await #expect(throws: RemoteFilesError.self) { _ = try await files.list("/does/not/exist") }
        await shell.close()
    }

    /// Only touches a workspace it creates itself in the isolated test session.
    @Test func createsWorkspaceWithCwdInTestSession() async throws {
        let c = ITConfig.current!
        let shell = try await c.connect()
        let client = HerdrClient(shell: shell, session: c.session)
        try await client.connect()
        let ws = try await client.createWorkspace(cwd: "/tmp", label: "it-launch", focus: false)
        let pane = try #require(try await client.panes().first { $0.paneId == ws.rootPaneId })
        #expect(pane.cwd == "/tmp")
        _ = try await shell.exec(SocketCommand.login("herdr --session \(c.session) workspace close \(ws.workspaceId)"))
        #expect(try await client.workspaces().allSatisfy { $0.workspaceId != ws.workspaceId })
        await shell.close()
    }

    /// Starts Claude Code right after creating the workspace (shell may still be initialising), the way
    /// the app does. No prompt is sent. The workspace is closed afterwards.
    @Test func startsClaudeInFreshWorkspace() async throws {
        let c = ITConfig.current!
        let shell = try await c.connect()
        let client = HerdrClient(shell: shell, session: c.session)
        try await client.connect()
        let ws = try await client.createWorkspace(cwd: "/tmp", label: "it-claude", focus: false)
        var failure: Error?
        do {
            let name = HerdrClient.agentName(for: "/tmp/it-claude", existing: Set(try await client.agents().compactMap(\.name)))
            try await client.startAgent(name: name, kind: "claude", paneId: ws.rootPaneId)
            let agent = try await client.agents().first { $0.name == name }
            #expect(agent != nil, "agent \(name) not listed")
            #expect(agent?.paneId == ws.rootPaneId)
            let read = try await client.readAgent(name)
            #expect(!read.text.isEmpty)
        } catch { failure = error }
        _ = try await shell.exec(SocketCommand.login("herdr --session \(c.session) workspace close \(ws.workspaceId)"))
        await shell.close()
        if let failure { throw failure }
    }

    @Test func makesFolderWithSpacesAndQuotes() async throws {
        let shell = try await ITConfig.current!.connect()
        let files = RemoteFiles(shell: shell)
        let base = "/tmp/herdrapp-it-\(Int.random(in: 1000...9999))"
        _ = try await shell.exec("mkdir -p \(base)")
        let made = try await files.makeDirectory(in: base, named: "neues 'Projekt' ä")
        #expect(try await files.list(base).entries.map(\.name) == ["neues 'Projekt' ä"])
        #expect(made == base + "/neues 'Projekt' ä")
        await #expect(throws: RemoteFilesError.self) { _ = try await files.makeDirectory(in: base, named: "neues 'Projekt' ä") }
        _ = try await shell.exec("rm -rf \(base)")
        await shell.close()
    }
}
