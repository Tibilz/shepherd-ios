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
                            deleteError = "„\(key.label)“ wird noch von einem Server genutzt."
                        } else {
                            try? model.deleteKey(key.id)
                        }
                    }
                }
            } footer: {
                Text("Private Keys liegen nur auf diesem iPhone im Schlüsselbund, geschützt mit Face ID. Sie werden nicht mit iCloud synchronisiert.")
            }
        }
        .navigationTitle("SSH-Keys")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label("Importieren", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $importing) { KeyImportView() }
        .alert("Nicht möglich", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") {}
        } message: { Text(deleteError ?? "") }
        .overlay {
            if model.keys.isEmpty {
                ContentUnavailableView("Keine Keys", systemImage: "key",
                                       description: Text("Kopiere deinen privaten Key aus deinem Passwort-Manager und füge ihn hier ein."))
            }
        }
    }
}

struct KeyDetailView: View {
    let key: StoredKeyRef
    @State private var copied = false

    var body: some View {
        Form {
            Section("Fingerabdruck") {
                Text(key.fingerprintSHA256).font(.footnote.monospaced()).textSelection(.enabled)
            }
            Section {
                Text(key.publicKeyOpenSSH).font(.caption2.monospaced()).textSelection(.enabled)
                Button(copied ? "Kopiert" : "Öffentlichen Key kopieren") {
                    UIPasteboard.general.string = key.publicKeyOpenSSH
                    copied = true
                }
            } header: { Text("Öffentlicher Key") } footer: {
                Text("Diese Zeile gehört auf dem Server in ~/.ssh/authorized_keys.")
            }
        }
        .navigationTitle(key.label)
    }
}
