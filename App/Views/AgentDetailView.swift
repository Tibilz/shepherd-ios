import HerdrKit
import SwiftUI

struct AgentDetailView: View {
    let serverId: UUID
    let target: String
    @Environment(AppModel.self) private var model
    @State private var read: AgentRead?
    @State private var input = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool
    @State private var session: LiveSession?
    @State private var connectError: String?
    @State private var voice: VoiceCoordinator?
    /// Parsed chat; nil when the output isn't Claude Code (then raw text is shown).
    @State private var blocks: [TranscriptBlock]?
    @State private var renaming: Agent?
    @AppStorage("agentRawOutput") private var rawOutput = false
    private var agent: Agent? { session?.snapshot?.agents.first { $0.name == target || $0.paneId == target } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if read?.truncated == true {
                            Text("Ältere Ausgabe gekürzt").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let blocks, !rawOutput {
                            TranscriptView(blocks: blocks)
                        } else {
                            Text(read?.text ?? "")
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .refreshable { await load() }
                .defaultScrollAnchor(.bottom)
                .onChange(of: read?.revision) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .overlay {
                    if read == nil {
                        if let connectError {
                            ContentUnavailableView {
                                Label("Nicht verbunden", systemImage: "bolt.horizontal.circle")
                            } description: { Text(connectError).textSelection(.enabled) } actions: {
                                Button("Erneut versuchen") { Task { await connect() } }.buttonStyle(.bordered)
                                Button("Fehler kopieren") { ErrorReport.copy(connectError) }
                            }
                        } else if agent == nil && session?.snapshot != nil {
                            ContentUnavailableView("Agent nicht gefunden", systemImage: "questionmark.circle",
                                                   description: Text("„\(target)“ läuft auf diesem Server gerade nicht."))
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
            if let agent, agent.agentStatus == .blocked {
                ApprovalBar { keys in Task { await send(keys: keys) } }
            }
            inputBar
        }
        .navigationTitle(agent?.displayName ?? target)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(agent?.displayName ?? target).font(.headline)
                    if let s = agent?.agentStatus { Text(s.label).font(.caption2).foregroundStyle(s.color) }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { renaming = agent } label: { Label("Umbenennen", systemImage: "pencil") }
                    .disabled(agent == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: $rawOutput) { Label("Rohausgabe", systemImage: "text.alignleft") }
            }
            if let cfg = model.notifyConfigs[serverId] {
                ToolbarItem(placement: .secondaryAction) {
                    let on = cfg.enabled && cfg.isEnabled(agent: target)
                    Button {
                        Task {
                            do { try await model.updateNotify(serverId) { $0.agents[target] = !on } }
                            catch { self.error = ErrorReport.text(error) }
                        }
                    } label: {
                        Label(on ? "Benachrichtigungen aus" : "Benachrichtigungen an", systemImage: on ? "bell.fill" : "bell.slash")
                    }
                    .disabled(!cfg.enabled)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.terminal(server: serverId, target: .agent(target))) {
                    Label("Terminal", systemImage: "apple.terminal")
                }
            }
        }
        .renameChat($renaming, session: session)
        .task(id: model.reconnectToken) { await connect() }
        .sheet(isPresented: Binding(get: { voice?.isActive ?? false }, set: { if !$0 { voice?.dismiss() } })) {
            if let voice { VoiceSheet(voice: voice) }
        }
        .onDisappear { voice?.dismiss() }
        .onAppear {
            model.visibleAgent = (serverId, target)
            if voice == nil { voice = VoiceCoordinator(model: model, serverId: serverId, agentTarget: target) }
        }
        .onDisappear { if model.visibleAgent?.server == serverId && model.visibleAgent?.target == target { model.visibleAgent = nil } }
        .task(id: agent?.revision) { await load() }
        .alert("Fehler", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Kopieren") { if let error { ErrorReport.copy(error) } }
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let voice { MicButton(voice: voice).scaleEffect(0.85) }
            TextField("Nachricht an \(agent?.displayName ?? target)", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
            Button {
                Task { await sendPrompt() }
            } label: {
                if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
            }
            .disabled(input.trimmed.isEmpty || sending || agent == nil)
            .accessibilityLabel("Senden")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Works for deep links too: the overview may never have been shown.
    private func connect() async {
        guard let profile = model.server(serverId) else { return }
        do {
            session = try await model.session(for: profile)
            connectError = nil
            if model.notifyConfigs[serverId] == nil { _ = try? await model.loadNotify(serverId) }
            await load()
        } catch is CancellationError {
        } catch {
            connectError = ErrorReport.text(error)
        }
    }

    private func load() async {
        guard let client = session?.client, agent != nil else { return }
        do {
            let r = try await client.readAgent(target)
            blocks = ClaudeTranscript.parse(r.text)
            read = r
        }
        catch is CancellationError {}
        catch { if read == nil { self.error = ErrorReport.text(error) } }
    }

    private func sendPrompt() async {
        guard let client = session?.client else { return }
        let text = input.trimmed
        sending = true
        defer { sending = false }
        do {
            try await client.prompt(target, text: text)
            input = ""
            inputFocused = false
        } catch {
            // Never resent automatically: the prompt may have arrived. The text stays in the field.
            self.error = "Senden fehlgeschlagen: \(ErrorReport.text(error))\nPrüfe die Ausgabe, bevor du es erneut versuchst."
        }
    }

    private func send(keys: [String]) async {
        guard let client = session?.client else { return }
        do {
            try await client.sendKeys(target, keys: keys)
            try? await Task.sleep(for: .milliseconds(400))
            await load()
        } catch {
            self.error = ErrorReport.text(error)
        }
    }
}

struct ApprovalBar: View {
    let send: ([String]) -> Void

    private let nav: [(label: String, symbol: String?, keys: [String])] = [
        ("Hoch", "arrow.up", ["up"]), ("Runter", "arrow.down", ["down"]), ("Tab", "arrow.right.to.line", ["tab"]),
    ]
    private let choices: [(String, [String])] = [
        ("1", ["1"]), ("2", ["2"]), ("3", ["3"]), ("y", ["y"]), ("n", ["n"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Der Agent wartet auf deine Antwort", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.red)
            HStack(spacing: 8) {
                ForEach(nav, id: \.label) { k in
                    Button { send(k.keys) } label: { Image(systemName: k.symbol ?? "questionmark").frame(minWidth: 28) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(k.label)
                }
                Button { send(["enter"]) } label: { Label("Enter", systemImage: "return").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(choices, id: \.0) { k in Button(k.0) { send(k.1) }.buttonStyle(.bordered) }
                    Button("Esc") { send(["esc"]) }.buttonStyle(.bordered).tint(.red)
                    Button("Ctrl+C") { send(["ctrl+c"]) }.buttonStyle(.bordered).tint(.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.06))
    }
}
