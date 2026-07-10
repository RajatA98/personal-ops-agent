import XCTest
import Core
@testable import Voice

@MainActor
final class TTSRouterTests: XCTestCase {

    // Happy path: a healthy primary serves playback; the fallback is never used.
    func test_healthyPrimary_usesPrimary() async throws {
        let primary = FakeTextToSpeech(behavior: .complete)
        let fallback = FakeTextToSpeech(behavior: .complete)
        let router = TTSRouter(primary: primary, fallback: fallback, primaryHealthy: true)

        try await router.speak("hello")

        XCTAssertEqual(primary.spokenTexts, ["hello"])
        XCTAssertTrue(fallback.spokenTexts.isEmpty)
        XCTAssertFalse(router.lastUsedFallback)
        XCTAssertEqual(router.state, .idle)
    }

    // ACCEPTANCE: a simulated primary (ElevenLabs) failure falls back to the system voice WITHOUT
    // breaking the conversation — speak() still succeeds, the answer is still spoken.
    func test_primaryFailure_fallsBackToSecondary_conversationContinues() async throws {
        let primary = FakeTextToSpeech(behavior: .fail(AppError.voice(.ttsFailed)))
        let fallback = FakeTextToSpeech(behavior: .complete)
        let router = TTSRouter(primary: primary, fallback: fallback, primaryHealthy: true)

        try await router.speak("your top priority is the swim")

        XCTAssertEqual(fallback.spokenTexts, ["your top priority is the swim"])
        XCTAssertTrue(router.lastUsedFallback)
        XCTAssertFalse(router.primaryHealthy, "primary should be marked unhealthy after a failure")
        XCTAssertEqual(router.state, .idle)
    }

    // Once the primary has failed, subsequent turns go straight to the fallback (no re-attempt).
    func test_afterFailure_staysOnFallback() async throws {
        let primary = FakeTextToSpeech(behavior: .fail(AppError.voice(.ttsFailed)))
        let fallback = FakeTextToSpeech(behavior: .complete)
        let router = TTSRouter(primary: primary, fallback: fallback, primaryHealthy: true)

        try await router.speak("first")
        try await router.speak("second")

        XCTAssertEqual(primary.spokenTexts.count, 1, "primary tried once, then abandoned")
        XCTAssertEqual(fallback.spokenTexts, ["first", "second"])
    }

    // ACCEPTANCE: playback can be interrupted within the latency target — stop() flips the state
    // synchronously and halts the active provider.
    func test_interruption_haltsWithinLatencyTarget() async throws {
        let primary = FakeTextToSpeech(behavior: .blockUntilStopped)
        let fallback = FakeTextToSpeech(behavior: .complete)
        let router = TTSRouter(primary: primary, fallback: fallback, primaryHealthy: true)

        let speaking = Task { try await router.speak("a long answer") }
        // Wait until playback is actually in progress.
        try await waitUntil { router.state == .speaking }

        let clock = ContinuousClock()
        let elapsed = await clock.measure { await router.stop() }

        XCTAssertEqual(router.state, .idle)
        XCTAssertEqual(primary.stopCallCount, 1)
        XCTAssertLessThan(elapsed, VoiceModule.interruptionLatencyTarget,
                          "interruption must take effect within the documented target")
        try await speaking.value   // the interrupted speak() returns cleanly
    }
}

/// Poll a condition on the main actor until true (or fail after a bounded number of hops).
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)   // 1ms
    }
    XCTFail("condition never became true", file: file, line: line)
}
