import Foundation
import HerdrKit
import HerdrSSH
import Observation
import SwiftUI

/// One voice interaction: listen → interpret (local rules, else Claude) → confirm → act.
@MainActor @Observable
final class VoiceCoordinator {
    enum AnswerMode: String { case ask, text, audio }

    enum Job: Equatable {
        case agent(target: String)
        case file(path: String)
    }

    enum Phase: Equatable {
        case idle
        case listening
        case thinking(String)
        case confirmShell(command: String, explanation: String, cwd: String?, dangerous: Bool, secondStep: Bool)
        case running(command: String)
        case output(command: String, text: String, exitCode: Int32)
        case promptCountdown(target: String, name: String, text: String, remaining: Int)
        /// Countdown stopped because the user is editing; sending uses the edited transcript.
        case promptPaused(target: String, name: String)
        case askAnswerMode(Job)
        case answer(String)
        case unknown(String)
        case done(String)
        case error(String)
    }

    let serverId: UUID
    let agentTarget: String?
    let speech = SpeechInput()
    private(set) var phase: Phase = .idle
    /// Editable copy of what was heard.
    var transcript = ""
    private weak var model: AppModel?
    private var countdownTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    /// Every user action that supersedes the current interaction bumps this. Work that resumes
    /// after an await with an older value is dropped, so nothing happens after Abbrechen/editing.
    private var interaction = 0

    static let answerModeKey = "voiceAnswerMode"
    var answerMode: AnswerMode {
        AnswerMode(rawValue: UserDefaults.standard.string(forKey: Self.answerModeKey) ?? "") ?? .ask
    }

    init(model: AppModel, serverId: UUID, agentTarget: String?) {
        self.model = model
        self.serverId = serverId
        self.agentTarget = agentTarget
    }

    var isActive: Bool { phase != .idle }

    // MARK: - Listening

    func startListening() {
        cancelWork()
        interaction += 1
        let token = interaction
        transcript = ""
        phase = .listening
        Task {
            await speech.start(contextualStrings: vocabulary())
            // Permission denied, language/model unavailable …: show it right away; typing still works.
            if token == interaction, case .failed(let m) = speech.state { phase = .error(m) }
        }
    }

    func stopListening() {
        guard phase == .listening else { return }          // second release / double tap: ignore
        interaction += 1
        let token = interaction
        phase = .thinking("Processing …")
        Task {
            let heard = await speech.stop()
            guard token == interaction else { return }       // dismissed meanwhile
            if case .failed(let m) = speech.state { phase = .error(m); return }
            transcript = heard
            guard !heard.isEmpty else { phase = .unknown("I didn't hear anything. You can also type."); return }
            await handle(heard, token: token)
        }
    }

    // MARK: - Interpretation

    private var session: LiveSession? { model?.liveSession(for: serverId) }

    func context() -> VoiceContext {
        let agents = session?.snapshot?.orderedAgents ?? []
        let current = agentTarget.flatMap { t in agents.first { $0.target == t || $0.paneId == t } }
        return VoiceContext(agents: agents, currentAgent: current, cwd: current?.cwd)
    }

    private func vocabulary() -> [String] {
        let names = (session?.snapshot?.agents ?? []).flatMap { [$0.name, $0.displayAgent].compactMap { $0 } }
        return ["herdr", "Claude", "Claude Code", "Codex", "Agent", "git", "npm", "README", "Terminal", "Workspace"] + names
    }

    /// Runs the (possibly edited) transcript through local rules, then Claude.
    func handle(_ text: String, token: Int? = nil) async {
        cancelWork()
        if token == nil { interaction += 1 }
        let token = token ?? interaction
        let ctx = context()
        if let req = LocalIntentParser.shellRequest(text) {
            await interpretWithClaude(req, ctx, forceShell: true, token: token)
        } else if let intent = LocalIntentParser.parse(text, context: ctx) {
            await execute(intent, ctx, token: token)
        } else {
            await interpretWithClaude(text, ctx, forceShell: false, token: token)
        }
    }

    private func interpretWithClaude(_ text: String, _ ctx: VoiceContext, forceShell: Bool, token: Int) async {
        guard let shell = model?.shell(for: serverId) else { phase = .error("Not connected."); return }
        phase = .thinking("Claude is thinking …")
        do {
            let intent = try await ClaudeAssistant(shell: shell, language: SpeechInput.languageName).interpret(text, context: ctx, forceShell: forceShell)
            guard token == interaction else { return }
            await execute(intent, ctx, token: token)
        } catch {
            guard token == interaction else { return }
            phase = .error(ErrorReport.text(error))
        }
    }

    private func execute(_ intent: VoiceIntent, _ ctx: VoiceContext, token: Int) async {
        guard let model, token == interaction else { return }
        switch intent {
        case .navigateAgent(let target):
            model.pendingPath = [.server(serverId), .agent(server: serverId, target: target)]
            phase = .idle
        case .navigateBack:
            model.pendingPath = [.server(serverId)]
            phase = .idle
        case .openTerminal:
            let t: TerminalTarget = ctx.currentAgent.map { .agent($0.target) } ?? .session
            model.pendingPath = [.server(serverId)] + (ctx.currentAgent.map { [.agent(server: serverId, target: $0.target)] } ?? [])
                + [.terminal(server: serverId, target: t)]
            phase = .idle
        case .approve(let keys):
            guard let target = ctx.currentAgent?.target, let client = session?.client else { phase = .error("Not connected."); return }
            do {
                try await client.sendKeys(target, keys: keys)
                phase = .done("Sent: \(keys.joined(separator: " "))")
                await session?.refresh()
            } catch { phase = .error(ErrorReport.text(error)) }
        case .prompt(let text):
            guard let a = ctx.currentAgent else { phase = .unknown("Which agent should get the message?"); return }
            startCountdown(target: a.target, name: a.displayName, text: text)
        case .promptAgent(let target, let text):
            let name = ctx.agents.first { $0.target == target }?.displayName ?? target
            startCountdown(target: target, name: name, text: text)
        case .shell(let command, let explanation, let cwd):
            phase = .confirmShell(command: command, explanation: explanation, cwd: cwd,
                                  dangerous: CommandSafety.isDangerous(command), secondStep: false)
        case .summarizeAgent(let target):
            guard let t = target ?? ctx.currentAgent?.target else { phase = .unknown("Which agent should I summarize?"); return }
            startSummary(.agent(target: t))
        case .summarizeFile(let path):
            startSummary(.file(path: path))
        case .unknown(let q):
            phase = .unknown(q)
        }
    }

    // MARK: - Prompt countdown (3 s, cancellable)

    private func startCountdown(target: String, name: String, text: String) {
        let token = interaction
        phase = .promptCountdown(target: target, name: name, text: text, remaining: 3)
        countdownTask = Task { [weak self] in
            for remaining in stride(from: 2, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, token == self.interaction,
                      case .promptCountdown(let t, let n, let tx, _) = self.phase else { return }
                if remaining == 0 { await self.sendPrompt(target: t, text: tx); return }
                self.phase = .promptCountdown(target: t, name: n, text: tx, remaining: remaining)
            }
        }
    }

    func sendPromptNow() {
        guard case .promptCountdown(let t, _, let tx, _) = phase else { return }
        countdownTask?.cancel()
        Task { await sendPrompt(target: t, text: tx) }
    }

    /// The user started editing: stop the countdown and drop any interpretation still in flight.
    func pauseCountdown() {
        countdownTask?.cancel()
        interaction += 1
        switch phase {
        case .promptCountdown(let t, let n, let tx, _):
            transcript = tx
            phase = .promptPaused(target: t, name: n)
        case .thinking:
            phase = .unknown("Edit the text and tap “Interpret Again”.")
        default: break
        }
    }

    /// Sends the edited transcript to the agent the paused prompt was meant for.
    func sendEdited() {
        guard case .promptPaused(let t, _) = phase else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        interaction += 1
        Task { await sendPrompt(target: t, text: text) }
    }

    private func sendPrompt(target: String, text: String) async {
        guard let client = session?.client else { phase = .error("Not connected."); return }
        do {
            try await client.prompt(target, text: text)   // never retried automatically
            phase = .done("Sent to \(target).")
            await session?.refresh()
        } catch {
            phase = .error("Sending failed: \(ErrorReport.text(error))\nCheck the agent before you try again.")
        }
    }

    // MARK: - Shell (own SSH channel in the agent's folder)

    func confirmShell() {
        guard case .confirmShell(let cmd, let expl, let cwd, let dangerous, let second) = phase else { return }
        if dangerous && !second {
            phase = .confirmShell(command: cmd, explanation: expl, cwd: cwd, dangerous: true, secondStep: true)
            return
        }
        guard let shell = model?.shell(for: serverId) else { phase = .error("Not connected."); return }
        phase = .running(command: cmd)
        interaction += 1
        let token = interaction
        workTask = Task { [weak self] in
            do {
                let res = try await shell.exec(SocketCommand.login(ShellRun.script(command: cmd, cwd: cwd)))
                guard let self, token == self.interaction else { return }
                var text = String(decoding: res.stdout.prefix(200_000), as: UTF8.self)
                if res.stdout.count > 200_000 { text += "\n… (truncated)" }
                if res.exitCode == 124 { text += "\n… (stopped after 2 minutes)" }
                self.phase = .output(command: cmd, text: text.isEmpty ? "(no output)" : text, exitCode: res.exitCode)
            } catch is CancellationError {
            } catch {
                self?.phase = .error(ErrorReport.text(error))
            }
        }
    }

    // MARK: - Summaries

    private func startSummary(_ job: Job) {
        switch answerMode {
        case .ask: phase = .askAnswerMode(job)
        case .text: runSummary(job, speak: false)
        case .audio: runSummary(job, speak: true)
        }
    }

    func chooseAnswerMode(_ mode: AnswerMode, remember: Bool) {
        guard case .askAnswerMode(let job) = phase else { return }
        if remember { UserDefaults.standard.set(mode.rawValue, forKey: Self.answerModeKey) }
        runSummary(job, speak: mode == .audio)
    }

    private func runSummary(_ job: Job, speak: Bool) {
        guard let shell = model?.shell(for: serverId), let client = session?.client else { phase = .error("Not connected."); return }
        phase = .thinking("Summarizing …")
        let token = interaction
        workTask = Task { [weak self] in
            do {
                let assistant = ClaudeAssistant(shell: shell, language: SpeechInput.languageName)
                let text: String
                switch job {
                case .agent(let target):
                    let read = try await client.readAgent(target)
                    text = try await assistant.summarize(agentOutput: read.text, agentName: target)
                case .file(let path):
                    text = try await assistant.summarize(file: path)
                }
                guard let self, token == self.interaction else { return }
                self.phase = .answer(text)
                if speak { Speaker.shared.say(text) }
            } catch is CancellationError {
            } catch {
                self?.phase = .error(ErrorReport.text(error))
            }
        }
    }

    // MARK: - Misc

    func reinterpret() {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task { await handle(t) }
    }

    private func cancelWork() {
        countdownTask?.cancel()
        workTask?.cancel()
        Speaker.shared.stop()
    }

    func dismiss() {
        cancelWork()
        interaction += 1
        if speech.state != .idle { Task { await speech.cancel() } }
        phase = .idle
    }
}
