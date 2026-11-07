import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("voiceLocale") private var locale = "de-DE"
    @AppStorage(VoiceCoordinator.answerModeKey) private var answerMode = VoiceCoordinator.AnswerMode.ask.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sprache", selection: $locale) {
                        Text("Deutsch").tag("de-DE")
                        Text("Englisch (USA)").tag("en-US")
                    }
                    Picker("Zusammenfassungen", selection: $answerMode) {
                        Text("Jedes Mal fragen").tag(VoiceCoordinator.AnswerMode.ask.rawValue)
                        Text("Als Text").tag(VoiceCoordinator.AnswerMode.text.rawValue)
                        Text("Vorlesen").tag(VoiceCoordinator.AnswerMode.audio.rawValue)
                    }
                    Button("Stimme testen") {
                        Speaker.shared.say(locale.hasPrefix("de") ? "So klingen die Antworten deiner Agents." : "This is how your agents' answers sound.")
                    }
                } header: { Text("Sprachsteuerung") } footer: {
                    Text("Die Spracherkennung läuft auf dem iPhone. Deutung und Zusammenfassungen übernimmt Claude Code auf deinem Server (dein Abo). Bessere Stimmen: Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen.")
                }
                Section("Über") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    Text("App-Symbol: herdr-Logo, Apache-2.0 (herdrdev/herdr)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}
