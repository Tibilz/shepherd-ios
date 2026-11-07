import HerdrKit
import SwiftUI

struct ServerEditView: View {
    let original: ServerProfile?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var keyId: UUID?
    @State private var herdrPath = "herdr"
    @State private var session = ""
    @State private var requiresVPN = false
    @State private var vpnApp = ""
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var confirmResetHostKey = false

    private var valid: Bool {
        !name.trimmed.isEmpty && !host.trimmed.isEmpty && !user.trimmed.isEmpty && Int(port).map { (1...65535).contains($0) } == true && keyId != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host or IP", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("User", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("SSH Key") {
                    Picker("Key", selection: $keyId) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(model.keys) { Text($0.label).tag(UUID?.some($0.id)) }
                    }
                }
                Section {
                    TextField("herdr path", text: $herdrPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("herdr session (empty = default)", text: $session)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("herdr") } footer: {
                    Text("Runs in a login shell. Usually “herdr” is enough.")
                }
                Section {
                    Toggle("Requires VPN", isOn: $requiresVPN)
                    if requiresVPN {
                        Picker("VPN app", selection: $vpnApp) {
                            Text("Not specified").tag("")
                            Text("WireGuard").tag("WireGuard")
                            Text("Cisco Secure Client").tag("Cisco Secure Client")
                            Text("OpenVPN Connect").tag("OpenVPN Connect")
                        }
                    }
                } header: { Text("Network") }
                if let error { Section { CopyableError(text: error) } }
                if let o = original, model.hasTrustedHostKey(host: o.host, port: o.port) {
                    Section {
                        Button("Reset Host Key", role: .destructive) { confirmResetHostKey = true }
                    } footer: {
                        Text("Only needed if the server was reinstalled. You will verify the new fingerprint on the next connection.")
                    }
                }
                if original != nil {
                    Section {
                        Button("Remove Server", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Removes the profile from the app only. Nothing on the server is changed.")
                    }
                }
            }
            .navigationTitle(original == nil ? "New Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
            }
            .confirmationDialog("Remove server?", isPresented: $confirmDelete) {
                Button("Remove", role: .destructive) {
                    if let original { try? model.deleteServer(original.id) }
                    dismiss()
                }
            }
            .confirmationDialog("Really reset the host key?", isPresented: $confirmResetHostKey, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    if let o = original { model.forgetHostKey(host: o.host, port: o.port); model.disconnect(o.id) }
                }
            } message: {
                Text("A changed host key can also mean an attack. Only reset it if you know why it changed.")
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let o = original else {
            keyId = model.keys.count == 1 ? model.keys[0].id : nil
            return
        }
        name = o.name; host = o.host; port = String(o.port); user = o.user; keyId = o.keyId
        herdrPath = o.herdrPath; session = o.session ?? ""; requiresVPN = o.requiresVPN; vpnApp = o.vpnApp ?? ""
    }

    private func save() {
        guard let keyId, let portNumber = Int(port) else { return }
        var p = original ?? ServerProfile(name: "", host: "", user: "", keyId: keyId)
        p.name = name.trimmed; p.host = host.trimmed; p.port = portNumber; p.user = user.trimmed; p.keyId = keyId
        p.herdrPath = herdrPath.trimmed.isEmpty ? "herdr" : herdrPath.trimmed
        p.session = session.trimmed.isEmpty ? nil : session.trimmed
        p.requiresVPN = requiresVPN
        p.vpnApp = requiresVPN && !vpnApp.isEmpty ? vpnApp : nil
        do {
            try model.saveServer(p)
            dismiss()
        } catch {
            self.error = ErrorReport.text(error)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
