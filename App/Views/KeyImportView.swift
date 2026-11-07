import HerdrKit
import HerdrSSH
import SwiftUI
import UniformTypeIdentifiers

struct KeyImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var pem = ""
    @State private var passphrase = ""
    @State private var remember = true
    @State private var needsPassphrase = false
    @State private var error: String?
    @State private var result: (StoredKeyRef, ParsedKey)?
    @State private var pickingFile = false
    @State private var fromClipboard = false
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            Form {
                if let (ref, parsed) = result {
                    importedSection(ref, parsed)
                } else {
                    Section("Name") {
                        TextField("VPS1", text: $label)
                    }
                    Section {
                        ZStack(alignment: .topLeading) {
                            if pem.isEmpty {
                                Text("-----BEGIN OPENSSH PRIVATE KEY-----\n…\n-----END OPENSSH PRIVATE KEY-----")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                            KeyTextView(text: $pem, masked: !showKey).frame(minHeight: 140)
                            if !showKey && !pem.isEmpty {
                                // Bullets in the same monospaced layout; the real text stays editable underneath.
                                Text(pem.map { $0 == "\n" ? "\n" : "•" }.reduce(into: "") { $0.append($1) })
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        Toggle(isOn: $showKey) { Label("Key anzeigen", systemImage: showKey ? "eye" : "eye.slash") }
                        .onChange(of: pem) { _, _ in validate() }
                        Button {
                            pem = UIPasteboard.general.string ?? ""
                            fromClipboard = true
                        } label: { Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") }
                        Button { pickingFile = true } label: { Label("Aus Datei wählen", systemImage: "folder") }
                    } header: { Text("Privater Key") } footer: {
                        Text("Eintippen oder ins Feld tippen und lange drücken → „Automatisch ausfüllen“ → dein Passwort-Manager → deinen SSH-Key wählen. Unterstützt werden OpenSSH-Keys (Ed25519 empfohlen).")
                    }
                    if needsPassphrase {
                        Section("Passphrase") {
                            SecureField("Passphrase", text: $passphrase)
                                .textContentType(.password)
                                .onSubmit(validate)
                            Toggle("Passphrase merken", isOn: $remember)
                        }
                    }
                    if let error { Section { CopyableError(text: error) } }
                }
            }
            .navigationTitle("SSH-Key importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Abbrechen" : "Fertig") { dismiss() }
                }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Importieren", action: save).disabled(pem.isEmpty || (needsPassphrase && passphrase.isEmpty))
                    }
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data, .text, .item]) { res in
                guard case .success(let url) = res else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                pem = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if label.isEmpty { label = url.lastPathComponent }
                fromClipboard = false
            }
        }
    }

    @ViewBuilder
    private func importedSection(_ ref: StoredKeyRef, _ parsed: ParsedKey) -> some View {
        Section {
            Label("„\(ref.label)“ importiert", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            if let w = parsed.warning { Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        Section("Fingerabdruck") { Text(ref.fingerprintSHA256).font(.footnote.monospaced()).textSelection(.enabled) }
        Section("Öffentlicher Key") {
            Text(ref.publicKeyOpenSSH).font(.caption2.monospaced()).textSelection(.enabled)
            Button("Kopieren") { UIPasteboard.general.string = ref.publicKeyOpenSSH }
        }
        if fromClipboard {
            Section {
                Button("Zwischenablage leeren") {
                    UIPasteboard.general.string = ""
                    fromClipboard = false
                }
            } footer: { Text("Dein privater Key liegt noch in der Zwischenablage.") }
        }
    }

    /// Cheap check while typing: header only (no decryption). Full check happens on import.
    private func validate() {
        error = nil
        guard !pem.trimmed.isEmpty else { needsPassphrase = false; return }
        do {
            _ = try SSHKeyImport.parse(pem, passphrase: nil)
            needsPassphrase = false
        } catch KeyImportError.needsPassphrase {
            needsPassphrase = true
        } catch {
            // Don't nag mid-typing until the END line is there.
            if pem.contains("-----END") { self.error = ErrorReport.text(error) }
        }
    }

    private func save() {
        do {
            result = try model.importKey(label: label.trimmed, pem: pem, passphrase: passphrase.isEmpty ? nil : passphrase,
                                         rememberPassphrase: remember)
            pem = ""
            passphrase = ""
        } catch KeyImportError.needsPassphrase {
            needsPassphrase = true
        } catch {
            self.error = ErrorReport.text(error)
        }
    }
}
