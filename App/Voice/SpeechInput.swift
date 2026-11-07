import AVFoundation
import Observation
import Speech

/// On-device speech-to-text with Apple's SpeechAnalyzer (iOS 26). The language model is managed by iOS.
@MainActor @Observable
final class SpeechInput {
    enum State: Equatable { case idle, starting, preparing(String), listening, failed(String) }

    private(set) var state: State = .idle
    private(set) var transcript = ""

    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private let engine = AVAudioEngine()
    private var feeder: AudioFeeder?
    private var resultsTask: Task<Void, Never>?
    private var finalized = AttributedString()
    /// Bumped by stop/cancel; a start() that resumes after an await with an old value gives up.
    private var generation = 0

    static var localeIdentifier: String { UserDefaults.standard.string(forKey: "voiceLocale") ?? "de-DE" }

    func start(contextualStrings: [String]) async {
        guard state == .idle || isFailed else { return }
        generation += 1
        let gen = generation
        state = .starting
        transcript = ""
        finalized = AttributedString()
        func stillWanted() throws { if gen != generation { throw CancellationError() } }
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw Problem("Kein Mikrofon-Zugriff. Erlaube ihn in Einstellungen → herdr → Mikrofon.")
            }
            try stillWanted()
            guard await Self.speechAuthorized() else {
                throw Problem("Keine Erlaubnis für Spracherkennung. Erlaube sie in Einstellungen → herdr.")
            }
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: Self.localeIdentifier)) else {
                throw Problem("Diese Sprache wird für die Spracherkennung nicht unterstützt.")
            }
            try stillWanted()
            let t = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                state = .preparing("Sprachmodell wird von iOS geladen …")
                try await req.downloadAndInstall()
            }
            try stillWanted()
            let a = SpeechAnalyzer(modules: [t])
            if !contextualStrings.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings[.general] = contextualStrings
                try await a.setContext(ctx)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
                throw Problem("Kein passendes Audioformat für die Spracherkennung.")
            }
            try await a.prepareToAnalyze(in: format)
            try stillWanted()

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            let input = engine.inputNode
            let feeder = AudioFeeder(from: input.outputFormat(forBus: 0), to: format, continuation: cont)
            self.feeder = feeder
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0), block: Self.tapBlock(feeder))
            engine.prepare()
            try engine.start()

            analyzer = a
            transcriber = t
            resultsTask = Task { [weak self] in
                do {
                    for try await r in t.results {
                        guard let self else { return }
                        if r.isFinal { self.finalized += r.text; self.transcript = String(self.finalized.characters) }
                        else { self.transcript = String((self.finalized + r.text).characters) }
                    }
                } catch {}
            }
            try await a.start(inputSequence: stream)
            try stillWanted()
            state = .listening
        } catch is CancellationError {
            if gen == generation { state = .idle }   // superseded: stop()/cancel() already cleaned up
        } catch let p as Problem {
            fail(p.message)
        } catch {
            fail(ErrorReport.text(error))
        }
    }

    /// Stops listening and returns the final transcript. Idempotent; during start-up it cancels instead.
    func stop() async -> String {
        switch state {
        case .listening: break
        case .starting, .preparing:
            await cancel()
            return ""
        default:
            return ""
        }
        generation += 1
        state = .idle
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feeder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        cleanup()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        generation += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feeder?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        cleanup()
        state = .idle
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    /// Built outside the main actor: AVAudioEngine calls the tap on its realtime thread, and a
    /// main-actor-isolated closure would trip Swift 6's runtime isolation check there.
    nonisolated private static func tapBlock(_ feeder: AudioFeeder) -> AVAudioNodeTapBlock {
        { buffer, _ in feeder.feed(buffer) }
    }

    private func fail(_ message: String) {
        let a = analyzer
        Task { await a?.cancelAndFinishNow() }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        feeder?.finish()
        cleanup()
        state = .failed(message)
    }

    private func cleanup() {
        analyzer = nil
        transcriber = nil
        feeder = nil
        resultsTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// nonisolated for the same reason: the authorization handler runs on a background queue.
    nonisolated private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private struct Problem: Error { let message: String; init(_ m: String) { message = m } }
}

/// Converts microphone buffers to the analyzer's format on the audio thread.
private final class AudioFeeder: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    init(from source: AVAudioFormat, to target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target
        self.continuation = continuation
        converter = source == target ? nil : AVAudioConverter(from: source, to: target)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { continuation.yield(AnalyzerInput(buffer: buffer)); return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() { continuation.finish() }
}
