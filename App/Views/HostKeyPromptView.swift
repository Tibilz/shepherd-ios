import SwiftUI

struct HostKeyPromptView: View {
    let prompt: HostKeyPrompt
    @State private var answered = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Du verbindest dich zum ersten Mal mit **\(prompt.serverName)** (\(prompt.host)). Prüfe den Fingerabdruck des Servers, bevor du ihm vertraust.")
                }
                Section("Fingerabdruck (SHA256)") {
                    Text(prompt.fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section {
                    Text("Auf dem Server anzeigen mit:\n`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Neuer Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { answer(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Vertrauen") { answer(true) }
                }
            }
        }
    }

    private func answer(_ ok: Bool) {
        guard !answered else { return }
        answered = true
        prompt.answer(ok)
    }
}
