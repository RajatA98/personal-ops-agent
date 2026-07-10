import Foundation
import Core

/// One transcribed utterance and how sure the recognizer was of it.
public struct Transcription: Equatable, Sendable {
    /// The recognized text (may be empty if nothing intelligible was heard).
    public let text: String
    /// Per-utterance confidence in `0...1`. Compared against
    /// `VoiceModule.lowConfidenceThreshold` to decide whether the transcript needs explicit
    /// confirmation before it can drive a Proposal / memory write.
    public let confidence: Double
    /// Whether this is the final result for the utterance (vs. a partial/interim hypothesis).
    public let isFinal: Bool

    public init(text: String, confidence: Double, isFinal: Bool = true) {
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
    }

    /// Whether this transcript may proceed straight to the model / a write without a confirmation
    /// step (i.e. it is confident enough).
    public var isConfident: Bool { confidence > VoiceModule.lowConfidenceThreshold }

    /// A transcript that has no usable content — the controller treats it as a no-op turn.
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// # SpeechToText — the on-device transcription boundary
///
/// A provider-swappable abstraction over speech recognition. The real implementation
/// (`AppleSpeechToText`) uses Apple's Speech framework with on-device recognition where
/// available (LOCKED_DECISIONS #7: keep raw audio on-device); tests inject a `FakeSpeechToText`
/// so `swift test` stays host-runnable and permission-free.
///
/// The contract is per-utterance push-to-talk: `requestAuthorization()` once, then `record()` to
/// capture a single utterance and return its final `Transcription`. `cancel()` aborts any
/// in-progress capture (the user let go / interrupted).
public protocol SpeechToText: Sendable {
    /// Ask the user for microphone + speech-recognition permission. Returns whether both were
    /// granted. Safe to call repeatedly (returns the current authorization).
    func requestAuthorization() async -> Bool

    /// Capture a single utterance from the microphone and return its final transcription.
    /// Throws `AppError.voice(.sttUnavailable)` when recognition is unavailable/denied.
    func record() async throws -> Transcription

    /// Abort any in-progress capture without producing a transcription.
    func cancel() async
}

// MARK: - Apple Speech implementation (on-device where available)

#if canImport(Speech) && canImport(AVFoundation)
import Speech
import AVFoundation

/// The real STT backed by Apple's Speech framework. On-device recognition is requested where the
/// locale/device supports it so raw voice audio never leaves the device (LOCKED_DECISIONS #7).
///
/// This type is compiled on any platform that ships Speech + AVFoundation, but it is **never
/// instantiated by `swift test`** — the unit tests use `FakeSpeechToText`, keeping them
/// permission-free and free of real microphone capture (which the simulator/host cannot provide
/// anyway). Real mic capture + on-device recognition quality are device-verified.
public final class AppleSpeechToText: SpeechToText, @unchecked Sendable {

    private let locale: Locale
    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    public func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        return await requestMicrophonePermission()
    }

    private func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
        #elseif os(macOS)
        // Phase 7B: macOS has no `AVAudioApplication` record-permission API — the microphone is a
        // capture *device*, so request access through `AVCaptureDevice`. The system shows its
        // prompt using the target's `NSMicrophoneUsageDescription`. Already-granted returns
        // immediately; the app is sandboxed with `com.apple.security.device.audio-input`.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #else
        return true
        #endif
    }

    public func record() async throws -> Transcription {
        guard let recognizer, recognizer.isAvailable else {
            throw AppError.voice(.sttUnavailable)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        // Prefer on-device recognition so audio stays local; fall back only if unsupported.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        defer {
            input.removeTap(onBus: 0)
            if audioEngine.isRunning { audioEngine.stop() }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Transcription, Error>) in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(returning: Self.transcription(from: result))
                } else if let error {
                    guard !resumed else { return }
                    resumed = true
                    _ = error
                    cont.resume(throwing: AppError.voice(.sttUnavailable))
                }
            }
        }
    }

    public func cancel() async {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }

    /// Average the recognized segments' confidence into a single per-utterance score.
    private static func transcription(from result: SFSpeechRecognitionResult) -> Transcription {
        let best = result.bestTranscription
        let segments = best.segments
        let confidence: Double
        if segments.isEmpty {
            confidence = 0
        } else {
            confidence = Double(segments.map(\.confidence).reduce(0, +)) / Double(segments.count)
        }
        return Transcription(text: best.formattedString, confidence: confidence, isFinal: true)
    }
}
#else
/// Stub for platforms without Speech/AVFoundation so the type always exists for composition; it
/// reports STT unavailable rather than crashing.
public final class AppleSpeechToText: SpeechToText, @unchecked Sendable {
    public init(locale: Locale = Locale(identifier: "en-US")) {}
    public func requestAuthorization() async -> Bool { false }
    public func record() async throws -> Transcription { throw AppError.voice(.sttUnavailable) }
    public func cancel() async {}
}
#endif
