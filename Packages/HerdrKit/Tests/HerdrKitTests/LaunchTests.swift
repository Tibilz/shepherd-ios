import Foundation
import Testing
@testable import HerdrKit

@Suite struct RemoteFilesTests {
    func listing(_ path: String, _ items: [(Character, String)], banner: String = "") -> ExecResult {
        var d = Data((banner + RemoteFiles.marker + "\n").utf8)
        d.append(Data(path.utf8)); d.append(0)
        for (t, n) in items { d.append(Data("\(t)\t\(n)".utf8)); d.append(0) }
        return ExecResult(stdout: d, stderr: Data(), exitCode: 0)
    }

    @Test func parsesListingDirsFirstSorted() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("pwd -P", listing("/home/ubuntu", [("f", "notes.txt"), ("d", "projects"), ("d", ".config"), ("d", "Apps"), ("f", "z b.md")], banner: "Welcome\n"))]
        let l = try await RemoteFiles(shell: shell).list(nil)
        #expect(l.path == "/home/ubuntu")
        #expect(l.entries.map(\.name) == ["Apps", "projects", ".config", "notes.txt", "z b.md"])
        #expect(l.entries[2].isHidden)
        #expect(l.entries[0].isDirectory && !l.entries[3].isDirectory)
        #expect(l.entries[0].path == "/home/ubuntu/Apps")
    }

    @Test func rootChildPath() {
        #expect(DirEntry(name: "etc", isDirectory: true, parent: "/").path == "/etc")
    }

    @Test func pathIsQuotedAndHomeIsDefault() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("pwd -P", listing("/x", []))]
        _ = try await RemoteFiles(shell: shell).list("/home/u/it's a dir")
        #expect(innerScript(shell.commands.last!).contains(#"P='/home/u/it'\''s a dir'"#))
        _ = try await RemoteFiles(shell: shell).list(nil)
        #expect(innerScript(shell.commands.last!).contains(#"P="$HOME""#))
    }

    @Test func unreadableDirThrows() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("pwd -P", ExecResult(stdout: Data((RemoteFiles.marker + "\n").utf8), stderr: Data("cd: /root: Permission denied".utf8), exitCode: 2))]
        await #expect(throws: RemoteFilesError.self) { _ = try await RemoteFiles(shell: shell).list("/root") }
    }

    @Test func parentOfPath() {
        #expect(RemoteFiles.parent(of: "/home/ubuntu/x") == "/home/ubuntu")
        #expect(RemoteFiles.parent(of: "/home") == "/")
        #expect(RemoteFiles.parent(of: "/") == nil)
    }
}

@Suite struct LaunchTests {
    @Test func agentNameFromFolder() {
        #expect(HerdrClient.agentName(for: "/home/u/herdr_app", existing: []) == "herdr_app")
        #expect(HerdrClient.agentName(for: "/home/u/My Project!", existing: []) == "my-project")
        #expect(HerdrClient.agentName(for: "/home/u/123", existing: []) == "a-123")
        #expect(HerdrClient.agentName(for: "/", existing: []) == "agent")
        #expect(HerdrClient.agentName(for: "/x/herdr_app", existing: ["herdr_app", "herdr_app-2"]) == "herdr_app-3")
        let long = HerdrClient.agentName(for: "/x/" + String(repeating: "abc", count: 20), existing: [])
        #expect(long.count <= 32)
        #expect(long.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil)
        #expect(HerdrClient.agentName(for: "/x/Übergröße", existing: []) == "uebergroesse")
    }

    @Test func createWorkspaceSendsCwdAndParsesIds() async throws {
        let shell = try runningShell()
        shell.responses["workspace.create"] = #"{"type":"workspace_created","workspace":{"workspace_id":"w7","number":7,"label":"herdr_app","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w7:t1","agent_status":"unknown"},"tab":{"tab_id":"w7:t1","workspace_id":"w7","number":1,"label":"1","focused":true,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w7:p1","tab_id":"w7:t1","workspace_id":"w7","terminal_id":"t","agent_status":"unknown","focused":true,"revision":0}}"#
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        let ws = try await client.createWorkspace(cwd: "/home/u/herdr app", label: "herdr app", focus: true)
        #expect(ws.workspaceId == "w7")
        #expect(ws.rootPaneId == "w7:p1")
        let p = try #require(shell.params(of: "workspace.create"))
        #expect(p["cwd"] as? String == "/home/u/herdr app")
        #expect(p["label"] as? String == "herdr app")
        #expect(p["focus"] as? Bool == true)
    }

    @Test func startAgentSendsParams() async throws {
        let shell = try runningShell()
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        try await client.startAgent(name: "herdr_app", kind: "claude", paneId: "w7:p1")
        let p = try #require(shell.params(of: "agent.start"))
        #expect(p["name"] as? String == "herdr_app")
        #expect(p["kind"] as? String == "claude")
        #expect(p["pane_id"] as? String == "w7:p1")
        #expect(p["timeout_ms"] as? Int == 60000)
    }

    /// Claude Code asks "trust this folder?" right away: herdr reports agent_not_ready, but it is running.
    @Test func blockedAtStartupCountsAsStarted() async throws {
        let shell = try runningShell()
        shell.errors["agent.start"] = (code: "agent_not_ready", message: "agent is blocked during startup")
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        try await client.startAgent(name: "x", kind: "claude", paneId: "w7:p1")
    }

    @Test func otherStartErrorsSurface() async throws {
        let shell = try runningShell()
        shell.errors["agent.start"] = (code: "pane_not_available", message: "pane busy")
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        await #expect(throws: HerdrError.server(code: "pane_not_available", message: "pane busy")) {
            try await client.startAgent(name: "x", kind: "claude", paneId: "w7:p1")
        }
    }

    @Test func agentKindsIncludeClaudeFirst() {
        #expect(HerdrClient.agentKinds.first?.kind == "claude")
        #expect(HerdrClient.agentKinds.contains { $0.kind == "codex" })
    }
}

@Suite struct MakeDirectoryTests {
    @Test func createsQuotedFolderAndReturnsPath() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("mkdir", out(RemoteFiles.marker + "\n"))]
        let p = try await RemoteFiles(shell: shell).makeDirectory(in: "/home/u", named: "  neues 'Projekt'  ")
        #expect(p == "/home/u/neues 'Projekt'")
        let cmd = innerScript(try #require(shell.commands.last))
        #expect(cmd.contains(#"mkdir -- '/home/u/neues '\''Projekt'\'''"#))
    }

    @Test func rejectsInvalidNames() async throws {
        let files = RemoteFiles(shell: FakeShell())
        for bad in ["", "   ", ".", "..", "a/b", "x\u{0}y"] {
            await #expect(throws: RemoteFilesError.invalidName) { _ = try await files.makeDirectory(in: "/home/u", named: bad) }
        }
    }

    @Test func serverErrorIsReported() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("mkdir", ExecResult(stdout: Data(), stderr: Data("mkdir: cannot create directory: File exists".utf8), exitCode: 1))]
        await #expect(throws: RemoteFilesError.self) { _ = try await RemoteFiles(shell: shell).makeDirectory(in: "/", named: "tmp") }
    }

    @Test func rootParent() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("mkdir", out(""))]
        #expect(try await RemoteFiles(shell: shell).makeDirectory(in: "/", named: "x") == "/x")
    }
}

@Suite struct AgentInstalledTests {
    @Test func missingExecutableThrowsClearError() async throws {
        let shell = try runningShell()
        shell.execHandlers = [("command -v", ExecResult(stdout: Data(), stderr: Data(), exitCode: 1))]
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        await #expect(throws: LaunchError.notInstalled(kind: "codex", label: "Codex")) { try await client.ensureInstalled(kind: "codex") }
    }

    @Test func presentExecutablePasses() async throws {
        let shell = try runningShell()
        shell.execHandlers = [("command -v", out("/home/u/.local/bin/claude\n"))]
        let client = HerdrClient(shell: shell)
        _ = try await client.connect()
        try await client.ensureInstalled(kind: "claude")
    }

    @Test func messageNamesTheAgent() {
        #expect(LaunchError.notInstalled(kind: "codex", label: "Codex").localizedDescription.contains("Codex"))
    }
}
