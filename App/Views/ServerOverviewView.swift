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
    @State private var renaming: Agent?

    private var profile: ServerProfile? { model.server(serverId) }

    var body: some View {
        List {
            ConnectionBanner(state: session?.state, error: error, profile: profile, retry: { Task { await connect() } })
            if let snap = session?.snapshot {
                if !snap.needsAttention.isEmpty {
                    Section("Braucht dich") {
                        ForEach(snap.needsAttention) { agent in
                            NavigationLink(value: Route.agent(server: serverId, target: agent.target)) { AgentRow(agent: agent) }
                                .contextMenu { Button { renaming = agent } label: { Label("Umbenennen", systemImage: "pencil") } }
                        }
                    }
                }
                ForEach(snap.workspaces) { ws in
                    Section {
                        ForEach(snap.tabs(in: ws)) { tab in
                            if snap.tabs(in: ws).count > 1 {
                                Text("Tab \(tab.label)").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(snap.panes(in: tab)) { pane in
                                if let agent = snap.agent(onPane: pane.paneId) {
                                    NavigationLink(value: Route.agent(server: serverId, target: agent.target)) { AgentRow(agent: agent) }
                                .contextMenu { Button { renaming = agent } label: { Label("Umbenennen", systemImage: "pencil") } }
                                } else {
                                    PaneRow(pane: pane)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(ws.number) · \(ws.label)")
                            Spacer()
                            if ws.agentStatus != .unknown { StatusBadge(status: ws.agentStatus, compact: true) }
                        }
                    }
                }
                if snap.workspaces.isEmpty {
                    ContentUnavailableView("Keine Workspaces", systemImage: "square.dashed",
                                           description: Text("In dieser herdr-Session gibt es noch keine Workspaces."))
                }
            } else if connecting {
                HStack { ProgressView(); Text("Verbinde …").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(profile?.name ?? "Server")
        .renameChat($renaming, session: session)
        .refreshable { await session?.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.folder(server: serverId, path: nil)) {
                    Label("Agent starten", systemImage: "plus")
                }
                .disabled(session == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink(value: Route.notifications(server: serverId)) {
                    Label("Benachrichtigungen", systemImage: "bell")
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
                HStack {
                    Text("Halten zum Sprechen")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    MicButton(voice: voice)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
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
            Button("Verbinden") { Task { await connect() } }
            Button("Abbrechen", role: .cancel) { passphrase = "" }
        } message: { Text("Der SSH-Key ist mit einer Passphrase geschützt.") }
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
            self.error = ErrorReport.text(error)
        }
    }
}

struct ConnectionBanner: View {
    let state: ConnectionState?
    let error: String?
    let profile: ServerProfile?
    let retry: () -> Void

    var body: some View {
        if let message {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Verbindung fehlgeschlagen", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    CopyableError(text: message)
                    if profile?.requiresVPN == true {
                        Text("Dieser Server braucht VPN. Ist \(profile?.vpnApp ?? "deine VPN-App") verbunden?")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Erneut versuchen", action: retry).buttonStyle(.bordered)
                }
            }
        } else if state == .polling {
            Section {
                Label("Live-Updates nicht verfügbar – aktualisiere alle 3 Sekunden.", systemImage: "arrow.triangle.2.circlepath")
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
        let path = agent.cwd.map { $0.replacingOccurrences(of: #"^/home/[^/]+"#, with: "~", options: .regularExpression) }
        let kind = agent.displayName == agent.kindLabel ? nil : agent.kindLabel
        return [kind, path].compactMap { $0 }.joined(separator: " · ")
    }
}

struct PaneRow: View {
    let pane: Pane
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.terminalTitleStripped ?? "Shell").font(.subheadline)
                if let cwd = pane.foregroundCwd ?? pane.cwd {
                    Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
