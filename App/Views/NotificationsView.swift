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
                HStack { ProgressView(); Text("Checking the server …").foregroundStyle(.secondary) }
            } else if let status, status.installed, let config {
                statusSection(status)
                subscribeSection(config)
                switchesSection(config)
                agentsSection(config)
                Section {
                    Button("Remove Notifications", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Removes the service and its files from the server. Your other settings stay untouched.")
                }
            } else if let status, status.installed {
                Section {
                    Label("The service is installed, but its configuration can't be read.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Remove Notifications", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("You can set them up again afterwards. That creates a new topic you need to subscribe to in ntfy.")
                }
            } else {
                setupSection(status)
            }
            if let error { Section { CopyableError(text: error) } }
        }
        .navigationTitle("Notifications")
        .disabled(busy)
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .task { await reload() }
        .refreshable { await reload() }
        .alert("Note", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK") {}
        } message: { Text(info ?? "") }
        .sheet(isPresented: $confirmInstall) { installSheet }
        .confirmationDialog("Remove notifications?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { run { try await model.uninstallNotify(serverId) } }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func setupSection(_ status: NotifyStatus?) -> some View {
        Section {
            Label("Push notifications when an agent needs you or is done", systemImage: "bell.badge")
            Text("A small service on the server sends them via ntfy. On your iPhone you need the free “ntfy” app.")
                .font(.footnote).foregroundStyle(.secondary)
            if status?.python == false {
                Label(NotifyError.pythonMissing.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button("Set Up …") { confirmInstall = true }
                .disabled(status?.python == false)
        }
    }

    private var installSheet: some View {
        NavigationStack {
            List {
                Section("What happens on \(profile?.name ?? "the server")") {
                    ForEach(NotifyInstaller(shell: NoShell()).plannedActions(linger: status?.linger ?? false, cron: status?.cron ?? false), id: \.self) {
                        Label($0, systemImage: "checkmark.circle")
                    }
                }
                Section {
                    Text("Messages go through the public ntfy.sh service. Anyone who knows your topic name (a random, secret code) can read them. Content: agent name, server name and status only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmInstall = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Up") {
                        confirmInstall = false
                        run {
                            let mode = try await model.installNotify(serverId)
                            if mode == .background {
                                info = "Running. After a server reboot, the app restarts the service the next time it connects."
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
                Label(s.running ? "Running" : "Stopped", systemImage: s.running ? "checkmark.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(s.running ? .green : .orange)
                Spacer()
                Text(modeLabel(s.mode)).font(.caption).foregroundStyle(.secondary)
            }
            Button("Send Test Notification") {
                run { try await model.sendTestNotification(serverId); info = "Test notification sent. It should appear on your iPhone shortly." }
            }
        } footer: {
            if s.mode == .background || s.mode == .cron, !s.linger, let user = profile?.user {
                Text("Optional, to start automatically after a server reboot: run `sudo loginctl enable-linger \(user)` once on the server, then remove and set up again here.")
            }
        }
    }

    @ViewBuilder
    private func subscribeSection(_ c: NotifyConfig) -> some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                if let qr = qrCode(c.subscribeURL.absoluteString) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                        .accessibilityLabel("QR code to subscribe")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Install the “ntfy” app").font(.footnote)
                    Text("2. In ntfy tap +, paste the topic").font(.footnote)
                    Text("3. Send a test notification").font(.footnote)
                }
            }
            Text(c.ntfyTopic).font(.footnote.monospaced()).textSelection(.enabled)
            Button("Copy Topic") { UIPasteboard.general.string = c.ntfyTopic }
            Link("ntfy on the App Store", destination: URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!)
        } header: { Text("Subscribe on iPhone") } footer: {
            Text("Server in ntfy: \(c.ntfyServer). Keep the topic name secret.")
        }
    }

    @ViewBuilder
    private func switchesSection(_ c: NotifyConfig) -> some View {
        Section("Notify me when …") {
            Toggle("Notifications enabled", isOn: binding(c.enabled) { $0.enabled = $1 })
            Toggle("an agent waits for approval", isOn: binding(c.events.blocked) { $0.events.blocked = $1 })
                .disabled(!c.enabled)
            Toggle("an agent is done", isOn: binding(c.events.done) { $0.events.done = $1 })
                .disabled(!c.enabled)
            Toggle("an agent is ready again", isOn: binding(c.events.idle) { $0.events.idle = $1 })
                .disabled(!c.enabled)
        }
    }

    @ViewBuilder
    private func agentsSection(_ c: NotifyConfig) -> some View {
        let live = model.liveSession(for: serverId)?.snapshot?.orderedAgents ?? []
        let liveKeys = live.map(\.target)
        let extra = c.agents.keys.filter { !liveKeys.contains($0) }.sorted()
        Section {
            Toggle("New agents by default", isOn: binding(c.defaultAgentEnabled) { $0.defaultAgentEnabled = $1 })
            ForEach(live) { a in
                Toggle(a.displayName, isOn: binding(c.isEnabled(agent: a.target)) { $0.agents[a.target] = $1 })
            }
            ForEach(extra, id: \.self) { key in
                Toggle(key, isOn: binding(c.isEnabled(agent: key)) { $0.agents[key] = $1 })
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Per Agent") } footer: {
            Text("Gray: agents that are not running right now.")
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
        case .background: "Background"
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
