import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("voiceLocale") private var locale = SpeechInput.defaultLocale
    @AppStorage(VoiceCoordinator.answerModeKey) private var answerMode = VoiceCoordinator.AnswerMode.ask.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $locale) {
                        Text("German").tag("de-DE")
                        Text("English (US)").tag("en-US")
                    }
                    Picker("Summaries", selection: $answerMode) {
                        Text("Ask every time").tag(VoiceCoordinator.AnswerMode.ask.rawValue)
                        Text("As text").tag(VoiceCoordinator.AnswerMode.text.rawValue)
                        Text("Read aloud").tag(VoiceCoordinator.AnswerMode.audio.rawValue)
                    }
                    Button("Test voice") {
                        Speaker.shared.say(locale.hasPrefix("de") ? "So klingen die Antworten deiner Agents." : "This is how your agents' answers sound.")
                    }
                } header: { Text("Voice Control") } footer: {
                    Text("Speech recognition runs on your iPhone. Claude Code on your server (your own subscription) interprets commands and writes summaries. Better voices: Settings → Accessibility → Spoken Content → Voices.")
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    Text("App icon: herdr logo, Apache-2.0 (herdrdev/herdr)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
