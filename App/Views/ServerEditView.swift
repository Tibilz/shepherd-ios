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
                    TextField("Host oder IP", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Benutzer", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("SSH-Key") {
                    Picker("Key", selection: $keyId) {
                        Text("Bitte wählen").tag(UUID?.none)
                        ForEach(model.keys) { Text($0.label).tag(UUID?.some($0.id)) }
                    }
                }
                Section {
                    TextField("herdr-Pfad", text: $herdrPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("herdr-Session (leer = Standard)", text: $session)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("herdr") } footer: {
                    Text("Der Pfad wird in einer Login-Shell ausgeführt. Normalerweise reicht „herdr“.")
                }
                Section {
                    Toggle("Braucht VPN", isOn: $requiresVPN)
                    if requiresVPN {
                        Picker("VPN-App", selection: $vpnApp) {
                            Text("Keine Angabe").tag("")
                            Text("WireGuard").tag("WireGuard")
                            Text("Cisco Secure Client").tag("Cisco Secure Client")
                            Text("OpenVPN Connect").tag("OpenVPN Connect")
                        }
                    }
                } header: { Text("Netzwerk") }
                if let error { Section { CopyableError(text: error) } }
                if let o = original, model.hasTrustedHostKey(host: o.host, port: o.port) {
                    Section {
                        Button("Host-Key zurücksetzen", role: .destructive) { confirmResetHostKey = true }
                    } footer: {
                        Text("Nur nötig, wenn der Server neu installiert wurde. Beim nächsten Verbinden musst du den neuen Fingerabdruck prüfen.")
                    }
                }
                if original != nil {
                    Section {
                        Button("Server entfernen", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Entfernt nur das Profil in der App. Auf dem Server wird nichts verändert.")
                    }
                }
            }
            .navigationTitle(original == nil ? "Neuer Server" : "Server bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern") { save() }.disabled(!valid) }
            }
            .confirmationDialog("Server entfernen?", isPresented: $confirmDelete) {
                Button("Entfernen", role: .destructive) {
                    if let original { try? model.deleteServer(original.id) }
                    dismiss()
                }
            }
            .confirmationDialog("Host-Key wirklich zurücksetzen?", isPresented: $confirmResetHostKey, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) {
                    if let o = original { model.forgetHostKey(host: o.host, port: o.port); model.disconnect(o.id) }
                }
            } message: {
                Text("Ein geänderter Host-Key kann auch ein Angriff sein. Setze ihn nur zurück, wenn du weißt, warum er sich geändert hat.")
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
