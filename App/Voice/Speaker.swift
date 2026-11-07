import AVFoundation

/// Reads answers aloud with the best installed voice for the speech language.
@MainActor
final class Speaker: NSObject {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func say(_ text: String) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    func stop() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) } }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = SpeechInput.localeIdentifier
        let prefix = String(lang.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang || $0.language.hasPrefix(prefix) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    /// Give the audio back to other apps (we ducked them) once speech ends.
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Self.release() }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Self.release() }
    nonisolated static func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
