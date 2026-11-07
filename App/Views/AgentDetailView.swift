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
    /// Chat shown; nil when the output isn't Claude Code (then raw text is shown).
    @State private var blocks: [TranscriptBlock]?
    /// Last full read; busy agents only return their visible screen, which is merged behind it.
    @State private var history: [TranscriptBlock] = []
    @State private var lines = 1000
    @State private var loading = false
    @State private var renaming: RenameItem?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var restored = false
    @AppStorage("agentRawOutput") private var rawOutput = false
    private var agent: Agent? { session?.snapshot?.agents.first { $0.name == target || $0.paneId == target } }
    private var key: String { "\(serverId)/\(target)" }
    private var busy: Bool { agent?.agentStatus == .working }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if read?.truncated == true, read?.source != "visible", lines < 10000 {
                        Button {
                            lines = lines < 3000 ? 3000 : 10000
                            Task { await load(force: true) }
                        } label: {
                            Label("Load Earlier Messages", systemImage: "arrow.up.circle").font(.footnote)
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                    }
                    if let blocks, !rawOutput {
                        TranscriptView(blocks: blocks, working: busy)
                    } else if let read {
                        Text(read.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if busy { WorkingRow(text: nil) }
                    }
                }
                .padding(12)
            }
            .scrollPosition($position, anchor: .top)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.visibleRect.maxY >= g.contentSize.height - 40
            } action: { _, bottom in atBottom = bottom }
            .refreshable { await load(force: true) }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom, read != nil || blocks != nil {
                    Button {
                        withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Jump to latest")
                }
            }
            .animation(.snappy, value: atBottom)
            .overlay {
                if read == nil && blocks == nil {
                    if !model.isOnline {
                        ContentUnavailableView {
                            Label("No Internet Connection", systemImage: "wifi.slash")
                        } description: { Text("Shepherd reconnects automatically when you're back online.") }
                    } else if let connectError {
                        ContentUnavailableView {
                            Label("Not connected", systemImage: "bolt.horizontal.circle")
                        } description: { Text(connectError).textSelection(.enabled) } actions: {
                            Button("Try Again") { Task { await connect() } }.buttonStyle(.bordered)
                            Button("Copy error") { ErrorReport.copy(connectError) }
                        }
                    } else if agent == nil && session?.snapshot != nil {
                        ContentUnavailableView("Agent not found", systemImage: "questionmark.circle",
                                               description: Text("“\(target)” is not running on this server right now."))
                    } else {
                        ProgressView()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if !model.isOnline && (read != nil || blocks != nil) {
                    Label("No Internet Connection", systemImage: "wifi.slash")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 4)
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
                Button { renaming = agent.map(RenameItem.init(agent:)) } label: { Label("Rename", systemImage: "pencil") }
                    .disabled(agent == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: $rawOutput) { Label("Raw output", systemImage: "text.alignleft") }
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
                        Label(on ? "Notifications off" : "Notifications on", systemImage: on ? "bell.fill" : "bell.slash")
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
        // Connect, then keep the chat current: output changes don't produce herdr events, so poll —
        // quickly while the agent works or waits, slower while it is idle.
        .task(id: model.reconnectToken) {
            await connect()
            while !Task.isCancelled {
                let fast = agent?.agentStatus == .working || agent?.agentStatus == .blocked
                try? await Task.sleep(for: fast ? .seconds(1.5) : .seconds(4))
                guard !Task.isCancelled else { break }
                if model.isOnline { await load() }
            }
        }
        .task(id: agent?.agentStatus) { await load() }
        .sheet(isPresented: Binding(get: { voice?.isActive ?? false }, set: { if !$0 { voice?.dismiss() } })) {
            if let voice { VoiceSheet(voice: voice) }
        }
        .onAppear {
            model.visibleAgent = (serverId, target)
            if voice == nil { voice = VoiceCoordinator(model: model, serverId: serverId, agentTarget: target) }
            if blocks == nil, let cached = model.transcripts[key] {
                blocks = cached
                history = cached
                restoreScroll()
            }
        }
        .onDisappear {
            voice?.dismiss()
            if model.visibleAgent?.server == serverId && model.visibleAgent?.target == target { model.visibleAgent = nil }
            // Remember where the user was: at the bottom (follow new output) or a block further up.
            model.chatScroll[key] = atBottom ? nil : position.viewID(type: String.self)
        }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Copy") { if let error { ErrorReport.copy(error) } }
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    /// First content: back to where the user left this chat, else to the newest message.
    private func restoreScroll() {
        guard !restored else { return }
        restored = true
        let saved = rawOutput ? nil : model.chatScroll[key]
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            if let saved, blocks.map({ TranscriptView.ids(for: $0).contains(saved) }) == true {
                position.scrollTo(id: saved, anchor: .top)
            } else {
                position.scrollTo(edge: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let voice { MicButton(voice: voice).scaleEffect(0.85) }
            TextField("Message \(agent?.displayName ?? target)", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
            Button {
                Task { await sendPrompt() }
            } label: {
                if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
            }
            .disabled(input.trimmed.isEmpty || sending || agent == nil)
            .accessibilityLabel("Send")
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
            await load(force: true)
        } catch is CancellationError {
        } catch {
            connectError = model.isOnline ? ErrorReport.text(error) : nil
        }
    }

    private func load(force: Bool = false) async {
        guard let client = session?.client, agent != nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await client.readAgent(target, lines: lines)
            if !force, r.text == read?.text, r.source == read?.source { return }
            var shown = ClaudeTranscript.parse(r.text)
            if let parsed = shown {
                if r.source == "visible" { shown = ClaudeTranscript.merge(history: history, screen: parsed) }
                else { history = parsed }
            }
            let follow = atBottom
            read = r
            blocks = shown
            if let shown { model.transcripts[key] = shown }
            if !restored {
                restoreScroll()
            } else if follow {
                // Was at the newest message: stay there as new output arrives.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(30))
                    withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
                }
            }
        }
        catch is CancellationError {}
        catch { if read == nil && blocks == nil && model.isOnline { self.error = ErrorReport.text(error) } }
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
            withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
            await load()
        } catch {
            // Never resent automatically: the prompt may have arrived. The text stays in the field.
            self.error = model.isOnline
                ? "Sending failed: \(ErrorReport.text(error))\nCheck the output before you try again."
                : "No internet connection. Your message is still in the text field."
        }
    }

    private func send(keys: [String]) async {
        guard let client = session?.client else { return }
        do {
            try await client.sendKeys(target, keys: keys)
            try? await Task.sleep(for: .milliseconds(400))
            await load(force: true)
        } catch {
            self.error = ErrorReport.text(error)
        }
    }
}

struct ApprovalBar: View {
    let send: ([String]) -> Void

    private let nav: [(label: String, symbol: String?, keys: [String])] = [
        ("Up", "arrow.up", ["up"]), ("Down", "arrow.down", ["down"]), ("Tab", "arrow.right.to.line", ["tab"]),
    ]
    private let choices: [(String, [String])] = [
        ("1", ["1"]), ("2", ["2"]), ("3", ["3"]), ("y", ["y"]), ("n", ["n"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The agent is waiting for you", systemImage: "exclamationmark.circle.fill")
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
