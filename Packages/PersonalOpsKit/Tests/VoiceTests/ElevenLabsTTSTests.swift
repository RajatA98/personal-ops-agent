import XCTest
import Core
import Integrations
@testable import Voice

@MainActor
final class ElevenLabsTTSTests: XCTestCase {

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // The real request-building path: POST to the voice endpoint, key in the xi-api-key header
    // (never the body), text in the JSON body; the returned audio bytes are handed to the player.
    func test_speak_buildsRequestAndPlaysReturnedAudio() async throws {
        let audio = Data("MP3-BYTES".utf8)
        MockURLProtocol.handler = { rec in
            XCTAssertEqual(rec.method, "POST")
            XCTAssertTrue(rec.url.path.contains("/v1/text-to-speech/"))
            XCTAssertEqual(rec.headers["xi-api-key"], "secret-key")
            XCTAssertEqual(rec.json?["text"] as? String, "good morning")
            XCTAssertFalse(String(decoding: rec.body ?? Data(), as: UTF8.self).contains("secret-key"),
                           "the API key must never appear in the request body")
            return (.make(rec.url, 200), audio)
        }
        let player = FakeAudioPlayer()
        let tts = ElevenLabsTTS(apiKey: "secret-key", transport: MockURLProtocol.transport(), player: player)

        try await tts.speak("good morning")

        XCTAssertEqual(player.playedByteCounts, [audio.count])
    }

    // A 5xx from ElevenLabs surfaces as a thrown error (so the router can fall back).
    func test_serverError_throws() async {
        MockURLProtocol.handler = { rec in (.make(rec.url, 500), Data("err".utf8)) }
        let tts = ElevenLabsTTS(apiKey: "k", transport: MockURLProtocol.transport(), player: FakeAudioPlayer())

        do {
            try await tts.speak("hi")
            XCTFail("expected a failure")
        } catch {
            // any thrown AppError is acceptable — the router treats it as "fall back".
        }
    }

    // ACCEPTANCE (end-to-end): a REAL ElevenLabsTTS with a failing transport, wired as the router
    // primary, falls back to the system voice without breaking the conversation.
    func test_realElevenLabsFailure_routerFallsBackToSystemVoice() async throws {
        MockURLProtocol.handler = { rec in (.make(rec.url, 500), Data("down".utf8)) }
        let primary = ElevenLabsTTS(apiKey: "k", transport: MockURLProtocol.transport(), player: FakeAudioPlayer())
        let fallback = FakeTextToSpeech(behavior: .complete)
        let router = TTSRouter(primary: primary, fallback: fallback, primaryHealthy: true)

        try await router.speak("your top priority is the swim")

        XCTAssertTrue(router.lastUsedFallback)
        XCTAssertEqual(fallback.spokenTexts, ["your top priority is the swim"])
    }

    // Interruptible playback through the real ElevenLabs → AudioPlayer path: stop() halts the
    // player and the in-flight speak() returns.
    func test_stop_haltsElevenLabsPlayback() async throws {
        let audio = Data("MP3".utf8)
        MockURLProtocol.handler = { rec in (.make(rec.url, 200), audio) }
        let player = FakeAudioPlayer(holdUntilStopped: true)
        let tts = ElevenLabsTTS(apiKey: "k", transport: MockURLProtocol.transport(), player: player)

        let speaking = Task { try await tts.speak("a long spoken answer") }
        try await waitUntil { player.playedByteCounts.isEmpty == false }

        await tts.stop()

        XCTAssertEqual(player.stopCallCount, 1)
        try await speaking.value
    }
}
