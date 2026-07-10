import XCTest
import Core
@testable import Voice

final class SpeechAndAudioSessionTests: XCTestCase {

    // The low-confidence threshold gate lives on Transcription (drives the confirmation flow).
    func test_transcription_confidenceGate() {
        XCTAssertTrue(Transcription(text: "clear speech", confidence: 0.9).isConfident)
        XCTAssertFalse(Transcription(text: "mumble", confidence: 0.5).isConfident)
        // At exactly the threshold it is NOT confident (strictly-greater gate → confirm).
        XCTAssertFalse(Transcription(text: "borderline", confidence: VoiceModule.lowConfidenceThreshold).isConfident)
        XCTAssertTrue(Transcription(text: "  ", confidence: 0.9).isEmpty)
    }

    // The FakeSpeechToText fixture returns scripted transcriptions without a mic/permission.
    func test_fakeSTT_returnsScriptedTranscription() async throws {
        let stt = FakeSpeechToText(Transcription(text: "what's on today", confidence: 0.88))
        let authorized = await stt.requestAuthorization()
        XCTAssertTrue(authorized)
        let t = try await stt.record()
        XCTAssertEqual(t.text, "what's on today")
        XCTAssertEqual(stt.recordCallCount, 1)
    }

    func test_fakeSTT_propagatesError() async {
        let stt = FakeSpeechToText(error: AppError.voice(.sttUnavailable))
        do { _ = try await stt.record(); XCTFail("expected throw") } catch {}
    }

    // Audio session handoff: record → idle → playback → idle, in order.
    func test_audioSession_recordPlaybackHandoff() async throws {
        let session = AudioSessionStateMachine()

        try await session.activate(.recording)
        var mode = await session.mode
        XCTAssertEqual(mode, .recording)

        await session.deactivate()
        mode = await session.mode
        XCTAssertEqual(mode, .idle)

        try await session.activate(.playback)
        mode = await session.mode
        XCTAssertEqual(mode, .playback)

        await session.deactivate()
        let history = await session.history()
        XCTAssertEqual(history, [.recording, .idle, .playback, .idle])
    }
}
