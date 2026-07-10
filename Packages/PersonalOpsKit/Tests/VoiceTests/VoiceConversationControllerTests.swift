import XCTest
import SwiftData
import Core
import Data
import Reasoning
import Agent
import Fixtures
@testable import Voice

@MainActor
final class VoiceConversationControllerTests: XCTestCase {

    private func controller(transcript: Transcription,
                            responder: FakeQAResponder,
                            tts: FakeTextToSpeech = FakeTextToSpeech(behavior: .complete))
        -> (VoiceConversationController, FakeSpeechToText) {
        let stt = FakeSpeechToText(transcript)
        let controller = VoiceConversationController(stt: stt, tts: tts, responder: responder)
        return (controller, stt)
    }

    // A confident transcript flows straight through: record → route → speak, ending idle.
    func test_confidentTranscript_routesAndSpeaks() async {
        let responder = FakeQAResponder(answer: "Your top priority today is the swim.")
        let tts = FakeTextToSpeech(behavior: .complete)
        let (controller, _) = controller(
            transcript: Transcription(text: "what's on today", confidence: 0.9),
            responder: responder, tts: tts)

        await controller.takeTurn()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(responder.askedQuestions, ["what's on today"])
        XCTAssertEqual(tts.spokenTexts, ["Your top priority today is the swim."])
        XCTAssertEqual(controller.turns.map(\.role), [.user, .assistant])
    }

    // ACCEPTANCE: a low-confidence transcript requires explicit confirmation before ANY model
    // call — it parks at .confirming and sends nothing.
    func test_lowConfidence_parksAndSendsNothing() async {
        let responder = FakeQAResponder(answer: "…")
        let tts = FakeTextToSpeech(behavior: .complete)
        let (controller, _) = controller(
            transcript: Transcription(text: "uh add a meeting maybe", confidence: 0.3),
            responder: responder, tts: tts)

        await controller.takeTurn()

        guard case .confirming = controller.state else {
            return XCTFail("expected .confirming, got \(controller.state)")
        }
        XCTAssertTrue(responder.askedQuestions.isEmpty, "must not reach the model before confirmation")
        XCTAssertTrue(tts.spokenTexts.isEmpty)
    }

    // Confirming a parked low-confidence transcript then routes it.
    func test_lowConfidence_confirm_proceeds() async {
        let responder = FakeQAResponder(answer: "Added to your inbox as a proposal.")
        let (controller, _) = controller(
            transcript: Transcription(text: "remind me about the offer", confidence: 0.3),
            responder: responder)

        await controller.takeTurn()
        await controller.confirm()

        XCTAssertEqual(responder.askedQuestions, ["remind me about the offer"])
        XCTAssertEqual(controller.state, .idle)
    }

    // Rejecting a parked low-confidence transcript discards it: nothing sent, display turn removed.
    func test_lowConfidence_reject_discards() async {
        let responder = FakeQAResponder(answer: "…")
        let (controller, _) = controller(
            transcript: Transcription(text: "garbled", confidence: 0.2),
            responder: responder)

        await controller.takeTurn()
        controller.reject()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(responder.askedQuestions.isEmpty)
        XCTAssertTrue(controller.turns.isEmpty, "the optimistic display turn is removed on reject")
    }

    // The "still working" progress cue surfaces when the turn runs past the quick path.
    func test_stillWorkingCue_surfaces() async {
        let responder = FakeQAResponder(answer: "Here's the answer.", rounds: 3, fireStillWorking: true)
        let (controller, _) = controller(
            transcript: Transcription(text: "what did I decide about the acme offer", confidence: 0.9),
            responder: responder)

        await controller.takeTurn()

        XCTAssertTrue(controller.surfacedStillWorking, "cue should have fired for a multi-round turn")
        XCTAssertEqual(controller.lastRounds, 3)
    }

    // ACCEPTANCE: playback is interruptible — interrupt() halts TTS and returns to idle.
    func test_interruptDuringPlayback_returnsToIdle() async throws {
        let responder = FakeQAResponder(answer: "a long spoken answer")
        let tts = FakeTextToSpeech(behavior: .blockUntilStopped)
        let (controller, _) = controller(
            transcript: Transcription(text: "tell me everything", confidence: 0.9),
            responder: responder, tts: tts)

        let turn = Task { await controller.takeTurn() }
        try await waitUntil { controller.state == .speaking }
        XCTAssertTrue(controller.canInterrupt)

        await controller.interrupt()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(tts.stopCallCount, 1)
        await turn.value
    }

    // An empty utterance is a no-op turn (returns to idle, nothing sent).
    func test_emptyTranscript_isNoOp() async {
        let responder = FakeQAResponder(answer: "…")
        let (controller, _) = controller(
            transcript: Transcription(text: "   ", confidence: 0.9),
            responder: responder)

        await controller.takeTurn()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(responder.askedQuestions.isEmpty)
        XCTAssertTrue(controller.turns.isEmpty)
    }

    // STT failure surfaces a visible error state, not a silent hang (PRD failure mode).
    func test_sttFailure_surfacesError() async {
        let responder = FakeQAResponder(answer: "…")
        let stt = FakeSpeechToText(error: AppError.voice(.sttUnavailable))
        let controller = VoiceConversationController(
            stt: stt, tts: FakeTextToSpeech(behavior: .complete), responder: responder)

        await controller.takeTurn()

        guard case .error = controller.state else {
            return XCTFail("expected .error, got \(controller.state)")
        }
    }

    // PRIVACY: a full voice Q&A turn against a real orchestrator persists NOTHING to memory — the
    // transcript is not stored (PRD: transcripts aren't memory unless confirmed/approved).
    func test_voiceQATurn_persistsNoMemory() async throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)

        // A scripted provider that answers with no tool calls (no propose, no memory write).
        let provider = FakeReasoningProvider(scriptedText: "I don't have anything on that.")
        let env = AgentEnvironment.with(provider: provider)
        let orchestrator = try XCTUnwrap(env.qaOrchestrator(context: context))
        let responder = OrchestratorQAResponder(orchestrator: orchestrator)

        let controller = VoiceConversationController(
            stt: FakeSpeechToText(Transcription(text: "what did I say about tokyo", confidence: 0.95)),
            tts: FakeTextToSpeech(behavior: .complete),
            responder: responder)

        await controller.takeTurn()

        // No memory rows of any kind were created by speaking.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Preference>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyLog>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OpenLoop>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Proposal>()), 0)
        XCTAssertEqual(controller.state, .idle)
    }
}
