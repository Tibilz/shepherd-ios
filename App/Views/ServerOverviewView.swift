import HerdrKit
import SwiftUI

struct ServerOverviewView: View {
    let serverId: UUID
    @Environment(AppModel.self) private var model
    @State private var session: LiveSession?
    @State private var error: String?
    @State private var askPassphrase = false
    @State private var passphrase = ""
    @State private var connecting = false
    @State private var voice: VoiceCoordinator?
    @State private var renaming: RenameItem?
    @State private var closing: ChatItem?
    @State private var actionError: String?
    @AppStorage("chatSort") private var sort: ChatSort = .workspace
    @AppStorage("voiceHintSeen") private var voiceHintSeen = false

    private var profile: ServerProfile? { model.server(serverId) }

    var body: some View {
        List {
            ConnectionBanner(state: session?.state, error: error, offline: !model.isOnline, profile: profile,
                             retry: { Task { await connect() } })
            if let snap = session?.snapshot {
                if !snap.attentionItems.isEmpty {
                    Section("Needs You") {
                        ForEach(snap.attentionItems) { row($0) }
                    }
                }
                ForEach(snap.chatGroups(sort)) { group in
                    Section {
                        ForEach(group.items) { row($0) }
                    } header: {
                        if let title = group.title {
                            HStack {
                                Text(title)
                                Spacer()
                                if let st = group.status, st != .unknown { StatusBadge(status: st, compact: true) }
                            }
                        }
                    }
                }
                if snap.workspaces.isEmpty {
                    ContentUnavailableView("No Workspaces", systemImage: "square.dashed",
                                           description: Text("This herdr session has no workspaces yet."))
                }
            } else if connecting && model.isOnline {
                HStack { ProgressView(); Text("Connecting …").foregroundStyle(.secondary) }
            }
        }
        .animation(.default, value: sort)
        .confirmationDialog(closing.map { "Close “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { item in
            Button(item.agent == nil ? "Close Terminal" : "Close Agent", role: .destructive) { Task { await close(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.agent == nil
                 ? "Closes this terminal in herdr and ends what runs in it."
                 : "Ends \(item.agent?.kindLabel ?? "the agent") and closes its pane in herdr. The chat can't be reopened.")
        }
        .alert("Couldn't Close", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("Copy") { if let actionError { ErrorReport.copy(actionError) } }
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .navigationTitle(profile?.name ?? "Server")
        .renameChat($renaming, session: session)
        .refreshable { await session?.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(ChatSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                .disabled(session?.snapshot == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.folder(server: serverId, path: nil)) {
                    Label("Start Agent", systemImage: "plus")
                }
                .disabled(session == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink(value: Route.notifications(server: serverId)) {
                    Label("Notifications", systemImage: "bell")
                }
                .disabled(session == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.terminal(server: serverId, target: .session)) {
                    Label("Terminal", systemImage: "apple.terminal")
                }
                .disabled(session == nil)
            }
        }
        .task(id: model.reconnectToken) { await connect() }
        .safeAreaInset(edge: .bottom) {
            if let voice, session?.snapshot != nil {
                HStack(spacing: 10) {
                    if !voiceHintSeen {
                        // Shown once; goes away after the first voice command or when closed.
                        HStack(spacing: 8) {
                            Text("Navigate and steer your agents by voice")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button { voiceHintSeen = true } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                                .accessibilityLabel("Dismiss hint")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                    }
                    Spacer()
                    MicButton(voice: voice)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .animation(.snappy, value: voiceHintSeen)
                .onChange(of: voice.phase) { _, p in if p == .listening { voiceHintSeen = true } }
            }
        }
        .sheet(isPresented: Binding(get: { voice?.isActive ?? false }, set: { if !$0 { voice?.dismiss() } })) {
            if let voice { VoiceSheet(voice: voice) }
        }
        .onDisappear { voice?.dismiss() }
        .onAppear { if voice == nil { voice = VoiceCoordinator(model: model, serverId: serverId, agentTarget: nil) } }
        .onChange(of: session?.snapshot) { _, snap in
            if let snap { model.recordCounts(for: serverId, snapshot: snap) }
        }
        .alert("Passphrase", isPresented: $askPassphrase) {
            SecureField("Passphrase", text: $passphrase).textContentType(.password)
            Button("Connect") { Task { await connect() } }
            Button("Cancel", role: .cancel) { passphrase = "" }
        } message: { Text("The SSH key is protected by a passphrase.") }
    }

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        Group {
            if let agent = item.agent {
                NavigationLink(value: Route.agent(server: serverId, target: agent.target)) { AgentRow(agent: agent) }
            } else {
                NavigationLink(value: Route.terminal(server: serverId, target: .pane(item.paneId))) { PaneRow(item: item) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { closing = item } label: { Label("Close", systemImage: "xmark") }.tint(.red)
            Button { renaming = RenameItem(item) } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
        }
        .contextMenu {
            Button { renaming = RenameItem(item) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { closing = item } label: { Label("Close", systemImage: "xmark") }
        }
    }

    private func close(_ item: ChatItem) async {
        guard let session else { return }
        do {
            try await session.client.closePane(item.paneId)
            await session.refresh()
        } catch {
            actionError = ErrorReport.text(error)
        }
    }

    private func connect() async {
        guard let profile, !connecting else { return }
        connecting = true
        defer { connecting = false }
        error = nil
        do {
            session = try await model.session(for: profile, passphrase: passphrase.isEmpty ? nil : passphrase)
            passphrase = ""
        } catch ConnectError.needsPassphrase {
            askPassphrase = true
        } catch is CancellationError {
        } catch {
            self.error = model.isOnline ? ErrorReport.text(error) : nil
        }
    }
}

struct ConnectionBanner: View {
    let state: ConnectionState?
    let error: String?
    var offline = false
    let profile: ServerProfile?
    let retry: () -> Void

    var body: some View {
        if offline {
            Section { OfflineNotice() }
        } else if let message {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Connection failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    CopyableError(text: message)
                    if profile?.requiresVPN == true {
                        Text("This server requires VPN. Is \(profile?.vpnApp ?? "your VPN app") connected?")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Try Again", action: retry).buttonStyle(.bordered)
                }
            }
        } else if state == .polling {
            Section {
                Label("Live updates unavailable – refreshing every 3 seconds.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var message: String? {
        if let error { return error }
        if case .failed(let m) = state { return m }
        return nil
    }
}

struct AgentRow: View {
    let agent: Agent
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(agent.agentStatus.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).font(.headline).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            StatusBadge(status: agent.agentStatus)
        }
    }

    /// "claude · ~/projekt" (the kind is left out when it already is the title).
    private var subtitle: String {
        let path = HerdrSnapshot.shortPath(agent.cwd)
        let kind = agent.displayName == agent.kindLabel ? nil : agent.kindLabel
        return [kind, path].compactMap { $0 }.joined(separator: " · ")
    }
}

struct PaneRow: View {
    let item: ChatItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(2)
                if let cwd = HerdrSnapshot.shortPath(item.cwd) {
                    Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Shown instead of connection errors while the iPhone has no network.
struct OfflineNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("No Internet Connection", systemImage: "wifi.slash").font(.headline).foregroundStyle(.orange)
            Text("Shepherd reconnects automatically when you're back online.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
