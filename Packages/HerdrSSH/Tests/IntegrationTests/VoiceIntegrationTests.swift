import Foundation
import Testing
import HerdrKit
@testable import HerdrSSH

/// Real `claude -p` on the server (user's subscription). Kept to three short calls.
@Suite(.enabled(if: ITConfig.current != nil), .serialized)
struct VoiceIntegrationTests {
    @Test func interpretsFolderListingAsSafeShell() async throws {
        let shell = try await ITConfig.current!.connect()
        let ctx = VoiceContext(agents: [], currentAgent: nil, cwd: "/home/ubuntu")
        let i = try await ClaudeAssistant(shell: shell).interpret("zeige mir die Ordner an", context: ctx, forceShell: false)
        guard case .shell(let cmd, let expl, let cwd) = i else { Issue.record("got \(i)"); return }
        #expect(!CommandSafety.isDangerous(cmd), "\(cmd)")
        #expect(!expl.isEmpty)
        #expect(cwd == "/home/ubuntu")
        await shell.close()
    }

    @Test func interpretsMessageToNamedAgent() async throws {
        let shell = try await ITConfig.current!.connect()
        let json = #"[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent_status":"idle","name":"reviewer","cwd":"/home/ubuntu/app"},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","agent_status":"working","name":"docs"}]"#
        let agents = try HerdrJSON.decoder.decode([Agent].self, from: Data(json.utf8))
        let ctx = VoiceContext(agents: agents, currentAgent: nil, cwd: "/home/ubuntu")
        let i = try await ClaudeAssistant(shell: shell).interpret("sag dem reviewer, er soll die Tests laufen lassen", context: ctx, forceShell: false)
        guard case .promptAgent(let target, let text) = i else { Issue.record("got \(i)"); return }
        #expect(target == "reviewer")
        #expect(text.lowercased().contains("test"))
        await shell.close()
    }

    @Test func summarizesFileWithReadTool() async throws {
        let shell = try await ITConfig.current!.connect()
        let dir = "/tmp/herdrapp-voice-\(Int.random(in: 1000...9999))"
        _ = try await shell.exec("mkdir -p \(dir) && printf 'Einkaufsliste:\\n- Milch\\n- Brot\\n- Kaffee\\n' > \(dir)/liste.txt")
        let s = try await ClaudeAssistant(shell: shell).summarize(file: "\(dir)/liste.txt")
        #expect(s.lowercased().contains("milch") || s.lowercased().contains("einkauf"), "\(s)")
        // Remove exactly what this test created.
        _ = try await shell.exec("unlink \(dir)/liste.txt; rmdir \(dir)")
        await shell.close()
    }
}
