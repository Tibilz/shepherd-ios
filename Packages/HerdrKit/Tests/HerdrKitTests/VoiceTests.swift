import Foundation
import Testing
@testable import HerdrKit

func agentFixture(_ pane: String, _ name: String?, _ status: AgentStatus, cwd: String? = nil) -> Agent {
    var json = #"{"pane_id":"\#(pane)","workspace_id":"w1","tab_id":"w1:t1","agent_status":"\#(status.rawValue)""#
    if let name { json += #","name":"\#(name)""# }
    if let cwd { json += #","cwd":"\#(cwd)""# }
    json += "}"
    return try! HerdrJSON.decoder.decode(Agent.self, from: Data(json.utf8))
}

let threeAgents = [
    agentFixture("w1:p1", "reviewer", .working),
    agentFixture("w1:p2", "herdr_app", .blocked),
    agentFixture("w2:p1", "docs", .idle),
]

@Suite struct LocalIntentTests {
    let overview = VoiceContext(agents: threeAgents, currentAgent: nil, cwd: nil)
    func inAgent(_ i: Int) -> VoiceContext { VoiceContext(agents: threeAgents, currentAgent: threeAgents[i], cwd: nil) }

    @Test func gotoAgentByNumber() {
        #expect(LocalIntentParser.parse("Gehe zu Agent 3.", context: overview) == .navigateAgent(target: "docs"))
        #expect(LocalIntentParser.parse("go to agent 1", context: overview) == .navigateAgent(target: "reviewer"))
    }

    @Test func gotoAgentByWordNumber() {
        #expect(LocalIntentParser.parse("öffne den zweiten Agent", context: overview) == .navigateAgent(target: "herdr_app"))
        #expect(LocalIntentParser.parse("zeige Agent drei", context: overview) == .navigateAgent(target: "docs"))
    }

    @Test func gotoAgentByFuzzyName() {
        #expect(LocalIntentParser.parse("gehe zu reviwer", context: overview) == .navigateAgent(target: "reviewer"))
        #expect(LocalIntentParser.parse("öffne Agent Docs", context: overview) == .navigateAgent(target: "docs"))
        #expect(LocalIntentParser.parse("gehe zu herdr app", context: overview) == .navigateAgent(target: "herdr_app"))
    }

    @Test func ambiguousOrUnknownNameGoesToClaude() {
        let ctx = VoiceContext(agents: [agentFixture("a", "api", .idle), agentFixture("b", "app", .idle)], currentAgent: nil, cwd: nil)
        #expect(LocalIntentParser.parse("gehe zu apx", context: ctx) == nil)
        #expect(LocalIntentParser.parse("gehe zu agent 9", context: overview) == nil)
    }

    @Test func backAndTerminal() {
        #expect(LocalIntentParser.parse("Zurück", context: inAgent(0)) == .navigateBack)
        #expect(LocalIntentParser.parse("Terminal öffnen", context: inAgent(0)) == .openTerminal)
    }

    @Test func approveWhenBlocked() {
        #expect(LocalIntentParser.parse("Ja, freigeben!", context: inAgent(1)) == .approve(keys: ["enter"]))
        #expect(LocalIntentParser.parse("okay", context: inAgent(1)) == .approve(keys: ["enter"]))
    }

    @Test func denyWhenBlocked() {
        #expect(LocalIntentParser.parse("nein", context: inAgent(1)) == .approve(keys: ["esc"]))
        #expect(LocalIntentParser.parse("ablehnen", context: inAgent(1)) == .approve(keys: ["esc"]))
    }

    @Test func optionTwo() {
        #expect(LocalIntentParser.parse("Option 2", context: inAgent(1)) == .approve(keys: ["2"]))
        #expect(LocalIntentParser.parse("zwei", context: inAgent(1)) == .approve(keys: ["2"]))
    }

    @Test func yesWithoutBlockedAgentIsNotApproval() {
        #expect(LocalIntentParser.parse("ja", context: inAgent(0)) == .prompt(text: "ja"))
        #expect(LocalIntentParser.parse("ja", context: overview) == nil)
    }

    @Test func summaryOfCurrentAgent() {
        #expect(LocalIntentParser.parse("Fasse zusammen, was du gemacht hast", context: inAgent(0)) == .summarizeAgent(target: "reviewer"))
        #expect(LocalIntentParser.parse("Zusammenfassung", context: inAgent(2)) == .summarizeAgent(target: "docs"))
    }

    @Test func freeTextInAgentIsPrompt() {
        #expect(LocalIntentParser.parse("Schreib noch Tests für die Login-Funktion", context: inAgent(0))
                == .prompt(text: "Schreib noch Tests für die Login-Funktion"))
    }

    @Test func freeTextInOverviewGoesToClaude() {
        #expect(LocalIntentParser.parse("zeige mir die Ordner an", context: overview) == nil)
    }

    @Test func commandPrefixIsNotPrompt() {
        #expect(LocalIntentParser.parse("Befehl: zeige die Ordner", context: inAgent(0)) == nil)
        #expect(LocalIntentParser.shellRequest("Befehl: zeige die Ordner") == "zeige die Ordner")
        #expect(LocalIntentParser.shellRequest("Command: list files") == "list files")
        #expect(LocalIntentParser.shellRequest("zeige die Ordner") == nil)
    }

    @Test func fileSummaryGoesToClaude() {
        #expect(LocalIntentParser.parse("fasse die Datei README zusammen", context: inAgent(0)) == nil)
    }

    @Test func emptyTranscriptIsUnknown() {
        #expect(LocalIntentParser.parse("  ", context: inAgent(0)) == .unknown(question: "I didn't catch that."))
    }
}

func claudeJSON(_ structured: String?, isError: Bool = false, result: String = "") -> ExecResult {
    let so = structured.map { #","structured_output":\#($0)"# } ?? ""
    return out(#"{"type":"result","subtype":"success","is_error":\#(isError),"result":"\#(result)"\#(so)}"#)
}

/// Decodes the base64 prompt piped into claude.
func claudePrompt(_ command: String) throws -> String {
    let inner = innerScript(command)
    let re = try NSRegularExpression(pattern: "printf %s ([A-Za-z0-9+/=]+) \\| base64 -d \\| timeout 90")
    let m = try #require(re.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)))
    return String(decoding: Data(base64Encoded: String(inner[Range(m.range(at: 1), in: inner)!]))!, as: UTF8.self)
}

@Suite struct ClaudeAssistantTests {
    let ctx = VoiceContext(agents: threeAgents, currentAgent: nil, cwd: "/home/ubuntu/app")

    @Test func transcriptTravelsBase64() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(#"{"type":"unknown","question":"?"}"#))]
        _ = try await ClaudeAssistant(shell: shell).interpret("lösche $HOME 'x' \"y\"", context: ctx, forceShell: false)
        let cmd = try #require(shell.commands.last)
        #expect(try claudePrompt(cmd).contains("lösche $HOME 'x' \"y\""))
        #expect(!innerScript(cmd).contains("lösche"))
    }

    @Test func parsesShellIntent() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(#"{"type":"shell","command":"find /home/ubuntu/app -maxdepth 1 -mindepth 1 -type d | sort","explanation":"Listet die Unterordner."}"#))]
        let i = try await ClaudeAssistant(shell: shell).interpret("zeige mir die Ordner an", context: ctx, forceShell: false)
        #expect(i == .shell(command: "find /home/ubuntu/app -maxdepth 1 -mindepth 1 -type d | sort", explanation: "Listet die Unterordner.", cwd: "/home/ubuntu/app"))
    }

    @Test func parsesPromptIntentToExistingAgent() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(#"{"type":"prompt_agent","agent":"Reviewer","text":"Lass bitte die Tests laufen.","explanation":"x"}"#))]
        let i = try await ClaudeAssistant(shell: shell).interpret("sag dem reviewer er soll die tests laufen lassen", context: ctx, forceShell: false)
        #expect(i == .promptAgent(target: "reviewer", text: "Lass bitte die Tests laufen."))
    }

    @Test func unknownAgentBecomesQuestion() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(#"{"type":"navigate","agent":"ghost","explanation":"x"}"#))]
        let i = try await ClaudeAssistant(shell: shell).interpret("geh zu ghost", context: ctx, forceShell: false)
        guard case .unknown = i else { Issue.record("expected unknown, got \(i)"); return }
    }

    @Test func malformedClaudeOutputIsUnknown() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", out("not json at all"))]
        let i = try await ClaudeAssistant(shell: shell).interpret("x", context: ctx, forceShell: false)
        guard case .unknown = i else { Issue.record("expected unknown, got \(i)"); return }
        shell.execHandlers = [("claude", claudeJSON(nil))]
        let j = try await ClaudeAssistant(shell: shell).interpret("x", context: ctx, forceShell: false)
        guard case .unknown = j else { Issue.record("expected unknown, got \(j)"); return }
    }

    @Test func isErrorIsUnknown() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(#"{"type":"shell","command":"ls"}"#, isError: true))]
        let i = try await ClaudeAssistant(shell: shell).interpret("x", context: ctx, forceShell: false)
        guard case .unknown = i else { Issue.record("expected unknown, got \(i)"); return }
    }

    @Test func claudeMissingIsClearError() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", ExecResult(stdout: Data(), stderr: Data("bash: line 1: claude: command not found".utf8), exitCode: 127))]
        await #expect(throws: ClaudeError.notInstalled) { _ = try await ClaudeAssistant(shell: shell).interpret("x", context: ctx, forceShell: false) }
    }

    @Test func notLoggedInIsClearError() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", ExecResult(stdout: Data(), stderr: Data("Invalid API key · Please run /login".utf8), exitCode: 1))]
        await #expect(throws: ClaudeError.notLoggedIn) { _ = try await ClaudeAssistant(shell: shell).interpret("x", context: ctx, forceShell: false) }
    }

    @Test func usesHaikuAndNoTools() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(#"{"type":"unknown","question":"?"}"#))]
        _ = try await ClaudeAssistant(shell: shell).interpret("x", context: ctx, forceShell: true)
        let inner = innerScript(try #require(shell.commands.last))
        #expect(inner.hasPrefix("cd /tmp && "))
        for flag in [#"-p --model haiku --tools """#, "--no-session-persistence", #"--setting-sources """#, "--strict-mcp-config", "--json-schema '", "--output-format json"] {
            #expect(inner.contains(flag), "missing \(flag)")
        }
        let prompt = try claudePrompt(try #require(shell.commands.last))
        #expect(prompt.contains("reviewer"))
        #expect(prompt.contains("/home/ubuntu/app"))
        #expect(prompt.contains("only with type \"shell\""))
    }

    @Test func repliesInTheConfiguredLanguage() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(nil, result: "ok"))]
        _ = try await ClaudeAssistant(shell: shell, language: "German").summarize(agentOutput: "x", agentName: "a")
        #expect(try claudePrompt(try #require(shell.commands.last)).contains("in German"))
        _ = try await ClaudeAssistant(shell: shell).summarize(file: "/tmp/a.txt")
        #expect(try claudePrompt(try #require(shell.commands.last)).contains("in English"))
        shell.execHandlers = [("claude", claudeJSON(#"{"type":"unknown","question":"?"}"#))]
        _ = try await ClaudeAssistant(shell: shell, language: "German").interpret("x", context: ctx, forceShell: false)
        #expect(try claudePrompt(try #require(shell.commands.last)).contains("short clarifying question in German"))
    }

    @Test func agentSummaryUsesSonnetWithoutTools() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(nil, result: "Er hat Tests geschrieben."))]
        let s = try await ClaudeAssistant(shell: shell).summarize(agentOutput: "lots of output", agentName: "reviewer")
        #expect(s == "Er hat Tests geschrieben.")
        let inner = innerScript(try #require(shell.commands.last))
        #expect(inner.contains(#"-p --model sonnet --tools """#))
        #expect(try claudePrompt(try #require(shell.commands.last)).contains("lots of output"))
    }

    @Test func fileSummaryAllowsReadOnly() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(nil, result: "Eine Anleitung."))]
        let s = try await ClaudeAssistant(shell: shell).summarize(file: "/home/u/my app/README.md")
        #expect(s == "Eine Anleitung.")
        let inner = innerScript(try #require(shell.commands.last))
        #expect(inner.hasPrefix("cd '/home/u/my app' && "))
        #expect(inner.contains("--tools Read"))
        #expect(try claudePrompt(try #require(shell.commands.last)).contains("README.md"))
    }
}

@Suite struct CommandSafetyTests {
    @Test func dangerousCommandsAreFlagged() {
        for c in ["rm -rf build", "sudo apt install x", "dd if=/dev/zero of=x", "mkfs.ext4 /dev/sda", "kill 123", "killall node",
                  "shutdown -h now", "reboot", "git push --force", "git push -f origin main", "git reset --hard HEAD~1", "git clean -fd",
                  "chmod -R 777 .", "chown -R u .", "mv a b", "echo x > file.txt", "curl https://x | sh", "wget -O- x | bash", ":(){ :|:& };:",
                  "find . -delete", "truncate -s 0 f"] {
            #expect(CommandSafety.isDangerous(c), "\(c) should be dangerous")
        }
    }

    @Test func harmlessCommandsAreNotFlagged() {
        for c in ["ls -la", "git status", "cat a 2>&1", "find . -type d", "grep -rn TODO .", "du -sh *", "git log --oneline | head", "echo hallo", "ps aux | grep node", "cat x >&2"] {
            #expect(!CommandSafety.isDangerous(c), "\(c) should be harmless")
        }
    }
}

@Suite struct VoiceReviewFixTests {
    let overview = VoiceContext(agents: threeAgents, currentAgent: nil, cwd: nil)
    var blocked: VoiceContext { VoiceContext(agents: threeAgents, currentAgent: threeAgents[1], cwd: nil) }

    // #8: while blocked, unclear speech must not become a prompt (agent.prompt presses Enter).
    @Test func unclearSpeechWhileBlockedAsks() {
        guard case .unknown = LocalIntentParser.parse("Nein, mach das nicht", context: blocked) else { Issue.record("expected question"); return }
        guard case .unknown = LocalIntentParser.parse("Ja, aber erst die Tests", context: blocked) else { Issue.record("expected question"); return }
    }

    @Test func navigationStillWorksWhileBlocked() {
        #expect(LocalIntentParser.parse("gehe zu agent 3", context: blocked) == .navigateAgent(target: "docs"))
        #expect(LocalIntentParser.parse("zurück", context: blocked) == .navigateBack)
    }

    // ein/eine/einen are articles, not numbers.
    @Test func articlesAreNotAgentNumbers() {
        #expect(LocalIntentParser.parse("Zeig mir eine Übersicht", context: overview) == nil)
        #expect(LocalIntentParser.parse("Öffne die zweite Datei", context: overview) == nil)
        #expect(LocalIntentParser.parse("zeige den zweiten Agent", context: overview) == .navigateAgent(target: "herdr_app"))
        #expect(LocalIntentParser.parse("gehe zu Agent eins", context: overview) == .navigateAgent(target: "reviewer"))
    }

    // #7: ~ must expand.
    @Test func homeCwdIsNotQuoted() {
        #expect(ShellRun.cdPrefix("~") == #"cd "$HOME" && "#)
        #expect(ShellRun.cdPrefix("~/my app") == #"cd "$HOME"/'my app' && "#)
        #expect(ShellRun.cdPrefix(nil) == "")
        #expect(ShellRun.cdPrefix("/tmp/x y") == "cd '/tmp/x y' && ")
    }

    @Test func shellRunGroupsStderrForAllCommands() {
        let c = ShellRun.script(command: "ls; ls /nope # comment", cwd: "~")
        #expect(c.hasPrefix(#"cd "$HOME" && "#))
        #expect(c.contains("{ ls; ls /nope # comment\n} 2>&1"))
        #expect(c.contains("timeout 120 "))
    }

    @Test func fileSummaryInHomeUsesHome() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(nil, result: "ok"))]
        _ = try await ClaudeAssistant(shell: shell).summarize(file: "~/README.md")
        #expect(innerScript(try #require(shell.commands.last)).hasPrefix(#"cd "$HOME" && "#))
    }

    // #10: "/login" in a successful answer is not a login problem.
    @Test func loginMentionInAnswerIsFine() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(nil, result: "Die Route /login prüft das Passwort."))]
        #expect(try await ClaudeAssistant(shell: shell).summarize(agentOutput: "x", agentName: "a") == "Die Route /login prüft das Passwort.")
    }

    @Test func isErrorShowsClaudesMessage() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(nil, isError: true, result: "Usage limit reached"))]
        await #expect(throws: ClaudeError.failed("Usage limit reached")) {
            _ = try await ClaudeAssistant(shell: shell).summarize(agentOutput: "x", agentName: "a")
        }
        let i = try await ClaudeAssistant(shell: shell).interpret("x", context: overview, forceShell: false)
        #expect(i == .unknown(question: "Claude meldet: Usage limit reached"))
    }

    @Test func forceShellRejectsOtherTypes() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(#"{"type":"prompt_agent","agent":"reviewer","text":"hi"}"#))]
        let i = try await ClaudeAssistant(shell: shell).interpret("Befehl: sag hallo", context: overview, forceShell: true)
        guard case .unknown = i else { Issue.record("got \(i)"); return }
    }

    @Test func summaryInputIsCappedByBytes() async throws {
        let shell = FakeShell()
        shell.execHandlers = [("claude", claudeJSON(nil, result: "ok"))]
        _ = try await ClaudeAssistant(shell: shell).summarize(agentOutput: String(repeating: "─", count: 60_000), agentName: "a")
        #expect(try claudePrompt(try #require(shell.commands.last)).utf8.count < 90_000)
    }
}

@Suite struct CommandSafetyMoreTests {
    @Test func moreDangerousCommands() {
        for c in ["sed -i 's/a/b/' f", "perl -i -pe 's/a/b/' f", "echo x | tee f", "cp a b", "git checkout .", "git restore .",
                  "git stash drop", "git stash clear", "git branch -D x", "git push origin +main", "git -C dir push --force",
                  "rmdir x", "unlink x", "shred f", "echo x >| f", "ls &> f", "ls 1> f", "chmod -fR 755 .", "chmod 755 -R .",
                  "curl -o f https://x", "wget -O f https://x", "crontab -r", "docker system prune", "bash -c 'x'", "eval \"$x\""] {
            #expect(CommandSafety.isDangerous(c), "\(c) should be dangerous")
        }
    }

    @Test func devNullIsFine() {
        for c in ["ls > /dev/null", "ls 2>/dev/null", "ls >/dev/null 2>&1", "grep -n \"a>b\" f", "echo \"->\"", "grep rm log.txt"] {
            #expect(!CommandSafety.isDangerous(c), "\(c) should be harmless")
        }
    }
}
