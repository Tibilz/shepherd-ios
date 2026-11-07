import HerdrKit
import SwiftUI

/// Shows what was heard and what will happen; every risky step waits for a tap.
struct VoiceSheet: View {
    @Bindable var voice: VoiceCoordinator
    @State private var rememberMode = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    transcriptSection
                    content
                }
                .padding()
            }
            .navigationTitle("Sprachbefehl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { voice.dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if voice.phase == .listening {
            HStack(spacing: 10) {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(.red)
                Text(voice.speech.transcript.isEmpty ? "Ich höre zu …" : voice.speech.transcript)
                    .foregroundStyle(voice.speech.transcript.isEmpty ? .secondary : .primary)
            }
            if case .preparing(let m) = voice.speech.state { Label(m, systemImage: "arrow.down.circle").font(.footnote) }
            if voice.speech.state == .starting { Text("Starte Mikrofon …").font(.footnote).foregroundStyle(.secondary) }
            Button { voice.stopListening() } label: { Label("Fertig", systemImage: "stop.circle.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.red)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Verstanden").font(.caption).foregroundStyle(.secondary)
                TextField("Was soll passieren?", text: $voice.transcript, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onChange(of: editing) { _, on in if on { voice.pauseCountdown() } }
                HStack {
                    Button("Erneut deuten") { editing = false; voice.reinterpret() }
                        .disabled(voice.transcript.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button { voice.startListening() } label: { Label("Neu sprechen", systemImage: "mic") }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch voice.phase {
        case .idle, .listening:
            EmptyView()
        case .thinking(let m):
            HStack { ProgressView(); Text(m).foregroundStyle(.secondary) }
        case .confirmShell(let cmd, let expl, let cwd, let dangerous, let second):
            VStack(alignment: .leading, spacing: 10) {
                Text(expl).font(.subheadline)
                Text(cmd).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                if let cwd { Text("in \(cwd)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                if dangerous {
                    Label(second ? "Wirklich ausführen? Das kann Daten verändern oder löschen."
                                 : "Dieser Befehl verändert oder löscht etwas.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.footnote.weight(.semibold))
                }
                HStack {
                    Button("Abbrechen", role: .cancel) { voice.dismiss() }.buttonStyle(.bordered)
                    Spacer()
                    Button(dangerous ? (second ? "Ja, wirklich ausführen" : "Ausführen …") : "Ausführen") { voice.confirmShell() }
                        .buttonStyle(.borderedProminent).tint(dangerous ? .red : .accentColor)
                }
            }
        case .running(let cmd):
            HStack { ProgressView(); Text(cmd).font(.caption.monospaced()).lineLimit(2) }
        case .output(let cmd, let text, let code):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(cmd).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if code != 0 { Text("Exit \(code)").font(.caption.bold()).foregroundStyle(.red) }
                }
                Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { UIPasteboard.general.string = text } label: { Label("Ausgabe kopieren", systemImage: "doc.on.doc") }
                    .font(.footnote).buttonStyle(.borderless)
            }
        case .promptCountdown(_, let name, let text, let remaining):
            VStack(alignment: .leading, spacing: 10) {
                Text("Nachricht an \(name)").font(.caption).foregroundStyle(.secondary)
                Text(text).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                ProgressView(value: Double(3 - remaining), total: 3)
                HStack {
                    Button("Abbrechen", role: .cancel) { voice.dismiss() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Jetzt senden (\(remaining))") { voice.sendPromptNow() }.buttonStyle(.borderedProminent)
                }
            }
        case .promptPaused(_, let name):
            VStack(alignment: .leading, spacing: 10) {
                Label("Angehalten – bearbeite den Text oben", systemImage: "pause.circle").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Abbrechen", role: .cancel) { voice.dismiss() }.buttonStyle(.bordered)
                    Spacer()
                    Button("An \(name) senden") { editing = false; voice.sendEdited() }
                        .buttonStyle(.borderedProminent)
                        .disabled(voice.transcript.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        case .askAnswerMode:
            VStack(alignment: .leading, spacing: 10) {
                Text("Wie möchtest du die Zusammenfassung?").font(.subheadline)
                HStack {
                    Button { voice.chooseAnswerMode(.text, remember: rememberMode) } label: { Label("Als Text", systemImage: "text.alignleft").frame(maxWidth: .infinity) }
                    Button { voice.chooseAnswerMode(.audio, remember: rememberMode) } label: { Label("Vorlesen", systemImage: "speaker.wave.2").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                Toggle("Nicht mehr fragen", isOn: $rememberMode).font(.footnote)
            }
        case .answer(let text):
            VStack(alignment: .leading, spacing: 10) {
                Text(text).textSelection(.enabled)
                HStack {
                    Button { Speaker.shared.say(text) } label: { Label("Vorlesen", systemImage: "speaker.wave.2") }
                    Button { Speaker.shared.stop() } label: { Label("Stopp", systemImage: "stop.fill") }
                    Spacer()
                    Button { UIPasteboard.general.string = text } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                }
                .font(.footnote).buttonStyle(.borderless)
            }
        case .unknown(let q):
            Label(q, systemImage: "questionmark.bubble").foregroundStyle(.orange)
        case .done(let m):
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let m):
            CopyableError(text: m)
        }
    }
}

/// Hold to talk (release = run), or tap to start and tap again to stop.
struct MicButton: View {
    let voice: VoiceCoordinator
    @State private var pressedAt: Date?

    var body: some View {
        let listening = voice.phase == .listening
        Image(systemName: listening ? "mic.fill" : "mic")
            .font(.title2)
            .foregroundStyle(listening ? .white : .accentColor)
            .frame(width: 44, height: 44)
            .background(listening ? Color.red : Color.accentColor.opacity(0.12), in: Circle())
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressedAt == nil else { return }
                        pressedAt = Date()
                        if voice.phase == .listening { voice.stopListening() } else { voice.startListening() }
                    }
                    .onEnded { _ in
                        defer { pressedAt = nil }
                        // Held longer than a tap: releasing finishes (push-to-talk). A short tap keeps listening.
                        if let t = pressedAt, Date().timeIntervalSince(t) > 0.4, voice.phase == .listening { voice.stopListening() }
                    }
            )
            .accessibilityLabel(listening ? "Aufnahme beenden" : "Sprachbefehl")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if voice.phase == .listening { voice.stopListening() } else { voice.startListening() } }
    }
}
