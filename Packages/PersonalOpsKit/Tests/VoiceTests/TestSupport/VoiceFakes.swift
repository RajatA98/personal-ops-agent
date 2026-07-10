import Foundation
import Core
import Agent
@testable import Voice

// MARK: - Fake SpeechToText

/// A scripted STT: hands back a preset `Transcription` (or throws) — no mic, no permission. The
/// `FakeSpeechToText` fixture the plan calls for.
final class FakeSpeechToText: SpeechToText, @unchecked Sendable {
    var authorized = true
    var scripted: Result<Transcription, Error>
    private(set) var recordCallCount = 0
    private(set) var cancelCallCount = 0

    init(_ transcription: Transcription) { self.scripted = .success(transcription) }
    init(error: Error) { self.scripted = .failure(error) }

    func requestAuthorization() async -> Bool { authorized }
    func record() async throws -> Transcription {
        recordCallCount += 1
        return try scripted.get()
    }
    func cancel() async { cancelCallCount += 1 }
}

// MARK: - Fake TextToSpeech

/// A fake TTS whose `speak(_:)` either completes immediately, throws (to trigger a router
/// fallback), or blocks until `stop()` (to test interruption). Records what it was asked to say.
final class FakeTextToSpeech: TextToSpeech, @unchecked Sendable {
    enum Behavior { case complete, fail(Error), blockUntilStopped }

    let behavior: Behavior
    private let lock = NSLock()
    private(set) var spokenTexts: [String] = []
    private(set) var stopCallCount = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(behavior: Behavior = .complete) { self.behavior = behavior }

    func speak(_ text: String) async throws {
        lock.withLock { spokenTexts.append(text) }
        switch behavior {
        case .complete:
            return
        case .fail(let error):
            throw error
        case .blockUntilStopped:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock(); blockedContinuation = cont; lock.unlock()
            }
        }
    }

    func stop() async {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            stopCallCount += 1
            let c = blockedContinuation
            blockedContinuation = nil
            return c
        }
        cont?.resume()
    }
}

// MARK: - Fake AudioPlayer

/// A fake audio layer for the ElevenLabs playback/interruption tests. `play(_:)` records the
/// bytes and, when `holdUntilStopped` is set, blocks until `stop()` — modeling audio that is
/// halted mid-playback.
final class FakeAudioPlayer: AudioPlayer, @unchecked Sendable {
    let holdUntilStopped: Bool
    private let lock = NSLock()
    private(set) var playedByteCounts: [Int] = []
    private(set) var stopCallCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(holdUntilStopped: Bool = false) { self.holdUntilStopped = holdUntilStopped }

    func play(_ audio: Data) async throws {
        lock.withLock { playedByteCounts.append(audio.count) }
        guard holdUntilStopped else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock(); continuation = cont; lock.unlock()
        }
    }

    func stop() async {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            stopCallCount += 1
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume()
    }
}

// MARK: - Fake VoiceQAResponding

/// A fake Q&A responder: fires the "still working" cue (if asked) and returns a scripted
/// `QAResult`, so the controller state machine is exercised without a live model.
@MainActor
final class FakeQAResponder: VoiceQAResponding {
    var result: QAResult
    var fireStillWorking: Bool
    var thrownError: Error?
    private(set) var askedQuestions: [String] = []

    init(answer: String, rounds: Int = 1, fireStillWorking: Bool = false) {
        self.result = QAResult(answer: answer, rounds: rounds, usedTools: [], forcedAnswer: false)
        self.fireStillWorking = fireStillWorking
    }

    func answer(question: String,
                onStillWorking: @escaping @MainActor () -> Void) async throws -> QAResult {
        askedQuestions.append(question)
        if let thrownError { throw thrownError }
        if fireStillWorking { onStillWorking() }
        return result
    }
}
