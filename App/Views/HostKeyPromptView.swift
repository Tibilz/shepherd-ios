import SwiftUI

struct HostKeyPromptView: View {
    let prompt: HostKeyPrompt
    @State private var answered = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This is your first connection to **\(prompt.serverName)** (\(prompt.host)). Check the server fingerprint before you trust it.")
                }
                Section("Fingerprint (SHA256)") {
                    Text(prompt.fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section {
                    Text("Show it on the server with:\n`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { answer(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") { answer(true) }
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
