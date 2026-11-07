import Foundation
import Testing
@testable import HerdrKit

/// Synthetic Claude Code screen in the shape herdr's `recent_unwrapped` read returns (width 60).
private let rule = String(repeating: "─", count: 60)
private let screen = """
❯ wie viele Dateien liegen im Ordner und welche davon sind
  am größten?

  Ran 2 shell commands

● Im Ordner liegen 12 Dateien. Die größte ist `data.db` mit
  4 MB, danach kommen die Logs.
  - Erster Punkt einer Liste, die bewusst so lang ist, dass
    sie umbricht.
  - Zweiter Punkt

  ┌──────┬─────┐
  │ Name │ MB  │
  ├──────┼─────┤
  │ a.db │ 4   │
  └──────┴─────┘

● Bash(cd /home/ubuntu && ls -la
      | head)
  ⎿  total 12
     drwxr-x--- 5 ubuntu ubuntu 4096 .
     … +3 lines

✻ Crunched for 41s · done 6:25 PM

※ recap: Du wolltest wissen, wie groß die Dateien sind. Als
  Nächstes schaust du dir data.db an.

                         new task? /clear to save 104.4k tokens
\(rule)
❯\u{00A0}
\(rule)
  ⏵⏵ auto mode on (shift+tab to cycle)
"""

@Suite struct TranscriptTests {
    @Test func splitsIntoChatBlocks() throws {
        let blocks = try #require(ClaudeTranscript.parse(screen))
        #expect(blocks.count == 6)
        #expect(blocks[0] == .user("wie viele Dateien liegen im Ordner und welche davon sind am größten?"))
        #expect(blocks[1] == .meta("Ran 2 shell commands"))
        guard case .assistant(let segs) = blocks[2] else { Issue.record("\(blocks[2])"); return }
        #expect(segs.first == .prose("""
        Im Ordner liegen 12 Dateien. Die größte ist `data.db` mit 4 MB, danach kommen die Logs.
        - Erster Punkt einer Liste, die bewusst so lang ist, dass sie umbricht.
        - Zweiter Punkt
        """))
        guard case .preformatted(let table) = segs.last else { Issue.record("\(segs)"); return }
        #expect(table.hasPrefix("┌──────┬─────┐"))
        #expect(table.split(separator: "\n").count == 5)
        #expect(blocks[3] == .tool(title: "Bash(cd /home/ubuntu && ls -la | head)",
                                   detail: "total 12\ndrwxr-x--- 5 ubuntu ubuntu 4096 .\n… +3 lines"))
        #expect(blocks[4] == .meta("Crunched for 41s · done 6:25 PM"))
        #expect(blocks[5] == .recap("Du wolltest wissen, wie groß die Dateien sind. Als Nächstes schaust du dir data.db an."))
    }

    @Test func dropsClaudeInputBoxAndStatusLine() throws {
        let blocks = try #require(ClaudeTranscript.parse(screen))
        let all = blocks.map { "\($0)" }.joined()
        #expect(!all.contains("auto mode"))
        #expect(!all.contains("/clear"))
        #expect(!all.contains("───────────────────────────────"))
    }

    @Test func shortLinesAreNotJoined() throws {
        let blocks = try #require(ClaudeTranscript.parse("● Zeile eins\n  Zeile zwei\n\n  Neuer Absatz\n"))
        #expect(blocks == [.assistant([.prose("Zeile eins\nZeile zwei\n\nNeuer Absatz")])])
    }

    @Test func unknownLinesStayVisibleAsPreformatted() throws {
        let text = "● Darf ich das ausführen?\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"
        let blocks = try #require(ClaudeTranscript.parse(text))
        #expect(blocks.count == 2)
        #expect(blocks[1] == .other(" Do you want to proceed?\n ❯ 1. Yes\n   2. No"))
    }

    @Test func nonClaudeOutputReturnsNil() {
        #expect(ClaudeTranscript.parse("$ ls\nfoo bar\n$ codex\n> hallo\n") == nil)
        #expect(ClaudeTranscript.parse("") == nil)
    }

    @Test func textCutOffAtTheTopIsStillAnAnswer() throws {
        let text = "  Ende einer Antwort, deren Anfang fehlt.\n\n  ┌───┐\n  │ a │\n  └───┘\n\n  Fazit\n\n❯ danke\n"
        let blocks = try #require(ClaudeTranscript.parse(text))
        #expect(blocks == [
            .assistant([.prose("Ende einer Antwort, deren Anfang fehlt."), .preformatted("┌───┐\n│ a │\n└───┘"), .prose("Fazit")]),
            .user("danke"),
        ])
    }

    @Test func bangShellCommandAndLongOutput() throws {
        let text = "! cd /srv && npm test\n  ⎿  > test\n\n     PASS  eins\n     PASS  zwei\n\n● Alles grün.\n"
        let blocks = try #require(ClaudeTranscript.parse(text))
        #expect(blocks == [
            .tool(title: "$ cd /srv && npm test", detail: "> test\n\nPASS  eins\nPASS  zwei"),
            .assistant([.prose("Alles grün.")]),
        ])
    }

    @Test func welcomeBannerBecomesMeta() throws {
        let text = " ▐▛███▛█   Claude Code v2.1.318\n▝▜██████▀  Opus 5.5 · Claude Pro\n ▝▝   ▝▝   ~/app\n\n❯ hi\n"
        let blocks = try #require(ClaudeTranscript.parse(text))
        #expect(blocks.first == .meta("Claude Code v2.1.318 · Opus 5.5 · Claude Pro · ~/app"))
    }

    @Test func toolCallWithoutResult() throws {
        let blocks = try #require(ClaudeTranscript.parse("● Monitor(Progress of run)\n\n● Ich beobachte das.\n"))
        #expect(blocks == [.tool(title: "Monitor(Progress of run)", detail: ""), .assistant([.prose("Ich beobachte das.")])])
    }
}

@Suite struct ChatTitleTests {
    private func agent(_ extra: String) throws -> Agent {
        let json = #"{"pane_id":"w4:p1","workspace_id":"w4","tab_id":"w4:t1","agent_status":"idle","agent":"claude"\#(extra)}"#
        return try HerdrJSON.decoder.decode(Agent.self, from: Data(json.utf8))
    }

    @Test func usesClaudeChatTitleWhenUnnamed() throws {
        #expect(try agent(#","terminal_title_stripped":"Eval-Skill für DataDetective""#).displayName == "Eval-Skill für DataDetective")
    }

    @Test func ignoresShellPromptTitles() throws {
        #expect(try agent(#","terminal_title_stripped":"ubuntu@myhost: ~""#).displayName == "claude")
        #expect(try agent(#","terminal_title_stripped":"  ""#).displayName == "claude")
    }

    @Test func labelBeatsNameBeatsTitle() throws {
        var a = try agent(#","name":"reviewer","terminal_title_stripped":"Titel""#)
        #expect(a.displayName == "reviewer")
        a.label = "Mein Chat"
        #expect(a.displayName == "Mein Chat")
        #expect(a.target == "reviewer")          // commands still go to the herdr name
    }

    @Test func snapshotCopiesPaneLabelToAgent() throws {
        let pane = try HerdrJSON.decoder.decode(Pane.self, from: Data(#"{"pane_id":"w4:p1","tab_id":"w4:t1","workspace_id":"w4","agent_status":"idle","label":"Datenbank-Check"}"#.utf8))
        #expect(pane.label == "Datenbank-Check")
        let snap = HerdrSnapshot(workspaces: [], tabs: [], panes: [pane], agents: [try agent("")])
        #expect(snap.agents[0].displayName == "Datenbank-Check")
        #expect(snap.agents[0].kindLabel == "claude")
    }
}
