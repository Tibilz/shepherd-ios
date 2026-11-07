import HerdrKit
import SwiftUI

struct KeyListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var deleteError: String?

    var body: some View {
        List {
            Section {
                ForEach(model.keys) { key in
                    NavigationLink { KeyDetailView(key: key) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.label).font(.headline)
                            Text("\(key.kind.rawValue.uppercased()) · \(key.fingerprintSHA256)")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx {
                        let key = model.keys[i]
                        if model.servers.contains(where: { $0.keyId == key.id }) {
                            deleteError = "“\(key.label)” is still used by a server."
                        } else {
                            try? model.deleteKey(key.id)
                        }
                    }
                }
            } footer: {
                Text("Private keys stay in this iPhone's keychain, protected by Face ID. They are not synced to iCloud.")
            }
        }
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label("Import", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $importing) { KeyImportView() }
        .alert("Not possible", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") {}
        } message: { Text(deleteError ?? "") }
        .overlay {
            if model.keys.isEmpty {
                ContentUnavailableView("No Keys", systemImage: "key",
                                       description: Text("Copy your private key from your password manager and paste it here."))
            }
        }
    }
}

struct KeyDetailView: View {
    let key: StoredKeyRef
    @State private var copied = false

    var body: some View {
        Form {
            Section("Fingerprint") {
                Text(key.fingerprintSHA256).font(.footnote.monospaced()).textSelection(.enabled)
            }
            Section {
                Text(key.publicKeyOpenSSH).font(.caption2.monospaced()).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Public Key") {
                    UIPasteboard.general.string = key.publicKeyOpenSSH
                    copied = true
                }
            } header: { Text("Public Key") } footer: {
                Text("Add this line to ~/.ssh/authorized_keys on the server.")
            }
        }
        .navigationTitle(key.label)
    }
}
