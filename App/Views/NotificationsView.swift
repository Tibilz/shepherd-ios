import CoreImage.CIFilterBuiltins
import HerdrKit
import SwiftUI

struct NotificationsView: View {
    let serverId: UUID
    @Environment(AppModel.self) private var model
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @State private var confirmInstall = false
    @State private var confirmRemove = false

    private var status: NotifyStatus? { model.notifyStatus[serverId] }
    private var config: NotifyConfig? { model.notifyConfigs[serverId] }
    private var profile: ServerProfile? { model.server(serverId) }

    var body: some View {
        Form {
            if loading {
                HStack { ProgressView(); Text("Prüfe den Server …").foregroundStyle(.secondary) }
            } else if let status, status.installed, let config {
                statusSection(status)
                subscribeSection(config)
                switchesSection(config)
                agentsSection(config)
                Section {
                    Button("Benachrichtigungen entfernen", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Entfernt den Dienst und seine Dateien vom Server. Deine übrigen Einstellungen bleiben unberührt.")
                }
            } else if let status, status.installed {
                Section {
                    Label("Der Dienst ist installiert, aber seine Konfiguration ist nicht lesbar.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Benachrichtigungen entfernen", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Danach kannst du sie neu einrichten. Dabei entsteht ein neuer Kanal, den du in ntfy neu abonnieren musst.")
                }
            } else {
                setupSection(status)
            }
            if let error { Section { CopyableError(text: error) } }
        }
        .navigationTitle("Benachrichtigungen")
        .disabled(busy)
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .task { await reload() }
        .refreshable { await reload() }
        .alert("Hinweis", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK") {}
        } message: { Text(info ?? "") }
        .sheet(isPresented: $confirmInstall) { installSheet }
        .confirmationDialog("Benachrichtigungen entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) { run { try await model.uninstallNotify(serverId) } }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func setupSection(_ status: NotifyStatus?) -> some View {
        Section {
            Label("Push-Nachrichten, wenn ein Agent auf dich wartet oder fertig ist", systemImage: "bell.badge")
            Text("Dafür läuft ein kleiner Dienst auf dem Server, der die Nachrichten über ntfy schickt. Auf dem iPhone brauchst du die kostenlose App „ntfy“.")
                .font(.footnote).foregroundStyle(.secondary)
            if status?.python == false {
                Label(NotifyError.pythonMissing.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button("Einrichten …") { confirmInstall = true }
                .disabled(status?.python == false)
        }
    }

    private var installSheet: some View {
        NavigationStack {
            List {
                Section("Das passiert auf \(profile?.name ?? "dem Server")") {
                    ForEach(NotifyInstaller(shell: NoShell()).plannedActions(linger: status?.linger ?? false, cron: status?.cron ?? false), id: \.self) {
                        Label($0, systemImage: "checkmark.circle")
                    }
                }
                Section {
                    Text("Nachrichten laufen über den öffentlichen Dienst ntfy.sh. Wer den Namen deines Kanals (ein zufälliger, geheimer Code) kennt, kann sie mitlesen. Inhalt: nur Agent-Name, Server-Name und Status.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einrichten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { confirmInstall = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Einrichten") {
                        confirmInstall = false
                        run {
                            let mode = try await model.installNotify(serverId)
                            if mode == .background {
                                info = "Läuft. Nach einem Neustart des Servers startet die App den Dienst beim nächsten Verbinden wieder."
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusSection(_ s: NotifyStatus) -> some View {
        Section {
            HStack {
                Label(s.running ? "Läuft" : "Gestoppt", systemImage: s.running ? "checkmark.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(s.running ? .green : .orange)
                Spacer()
                Text(modeLabel(s.mode)).font(.caption).foregroundStyle(.secondary)
            }
            Button("Testnachricht senden") {
                run { try await model.sendTestNotification(serverId); info = "Testnachricht verschickt. Sie sollte gleich auf deinem iPhone erscheinen." }
            }
        } footer: {
            if s.mode == .background || s.mode == .cron, !s.linger, let user = profile?.user {
                Text("Optional für automatischen Start nach einem Server-Neustart: einmal auf dem Server `sudo loginctl enable-linger \(user)` ausführen, danach hier entfernen und neu einrichten.")
            }
        }
    }

    @ViewBuilder
    private func subscribeSection(_ c: NotifyConfig) -> some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                if let qr = qrCode(c.subscribeURL.absoluteString) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                        .accessibilityLabel("QR-Code zum Abonnieren")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. App „ntfy“ installieren").font(.footnote)
                    Text("2. In ntfy auf + tippen, Kanal einfügen").font(.footnote)
                    Text("3. Testnachricht senden").font(.footnote)
                }
            }
            Text(c.ntfyTopic).font(.footnote.monospaced()).textSelection(.enabled)
            Button("Kanal kopieren") { UIPasteboard.general.string = c.ntfyTopic }
            Link("ntfy im App Store", destination: URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!)
        } header: { Text("Auf dem iPhone abonnieren") } footer: {
            Text("Server in ntfy: \(c.ntfyServer). Halte den Kanalnamen geheim.")
        }
    }

    @ViewBuilder
    private func switchesSection(_ c: NotifyConfig) -> some View {
        Section("Benachrichtigen, wenn …") {
            Toggle("Benachrichtigungen aktiv", isOn: binding(c.enabled) { $0.enabled = $1 })
            Toggle("ein Agent auf Freigabe wartet", isOn: binding(c.events.blocked) { $0.events.blocked = $1 })
                .disabled(!c.enabled)
            Toggle("ein Agent fertig ist", isOn: binding(c.events.done) { $0.events.done = $1 })
                .disabled(!c.enabled)
            Toggle("ein Agent wieder bereit ist", isOn: binding(c.events.idle) { $0.events.idle = $1 })
                .disabled(!c.enabled)
        }
    }

    @ViewBuilder
    private func agentsSection(_ c: NotifyConfig) -> some View {
        let live = model.liveSession(for: serverId)?.snapshot?.orderedAgents ?? []
        let liveKeys = live.map(\.target)
        let extra = c.agents.keys.filter { !liveKeys.contains($0) }.sorted()
        Section {
            Toggle("Neue Agents standardmäßig", isOn: binding(c.defaultAgentEnabled) { $0.defaultAgentEnabled = $1 })
            ForEach(live) { a in
                Toggle(a.displayName, isOn: binding(c.isEnabled(agent: a.target)) { $0.agents[a.target] = $1 })
            }
            ForEach(extra, id: \.self) { key in
                Toggle(key, isOn: binding(c.isEnabled(agent: key)) { $0.agents[key] = $1 })
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Pro Agent") } footer: {
            Text("Grau: Agents, die gerade nicht laufen.")
        }
        .disabled(!c.enabled)
    }

    // MARK: - Helpers

    private func binding(_ value: Bool, _ set: @escaping (inout NotifyConfig, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { new in run { try await model.updateNotify(serverId) { set(&$0, new) } } })
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            error = nil
            do { try await op() } catch { self.error = ErrorReport.text(error) }
        }
    }

    private func reload() async {
        defer { loading = false }
        do {
            if let p = profile { _ = try await model.session(for: p) }
            try await model.loadNotify(serverId)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = ErrorReport.text(error)
        }
    }

    private func modeLabel(_ m: NotifyMode) -> String {
        switch m {
        case .systemd: "systemd"
        case .cron: "cron"
        case .background: "Hintergrund"
        case .none: "—"
        }
    }

    private func qrCode(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Placeholder shell so plannedActions can be shown without a connection (it never executes).
private struct NoShell: RemoteShell {
    func exec(_ command: String) async throws -> ExecResult { throw HerdrError.transport("offline") }
    func stream(_ command: String) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
}
