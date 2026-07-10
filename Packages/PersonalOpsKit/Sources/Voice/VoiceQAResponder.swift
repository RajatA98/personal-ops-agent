import Foundation
import Agent

/// # VoiceQAResponding — the seam between a voice turn and the Q&A loop
///
/// A voice turn routes a confirmed transcript to the bounded tool-calling loop
/// (`QAOrchestrator.answer(question:)`) and speaks the answer (AGENT_DESIGN §1: voice is the Q&A
/// loop wrapped in STT/TTS). This protocol is that seam, with a progress hook so the controller
/// can surface a "still working" cue while a longer turn runs.
///
/// `onStillWorking` is the §2 progress affordance: it fires once the turn has clearly moved past
/// the quick path (~2 tool rounds). The merged `QAOrchestrator.answer(question:)` resolves
/// atomically — it does not emit per-round callbacks — so the production adapter approximates
/// "after round 2" with a short delay, and `QAResult.rounds` is surfaced afterward for
/// transparency. Tests inject a fake that fires the cue deterministically.
@MainActor
public protocol VoiceQAResponding {
    func answer(question: String,
                onStillWorking: @escaping @MainActor () -> Void) async throws -> QAResult
}

/// Production adapter over `QAOrchestrator`. Starts a timer when a turn begins; if the turn is
/// still running after `stillWorkingAfter` (a stand-in for "past ~2 rounds"), it fires the cue.
@MainActor
public struct OrchestratorQAResponder: VoiceQAResponding {
    private let orchestrator: QAOrchestrator
    private let stillWorkingAfter: Duration

    public init(orchestrator: QAOrchestrator, stillWorkingAfter: Duration = .seconds(4)) {
        self.orchestrator = orchestrator
        self.stillWorkingAfter = stillWorkingAfter
    }

    public func answer(question: String,
                       onStillWorking: @escaping @MainActor () -> Void) async throws -> QAResult {
        let delay = stillWorkingAfter
        let timer = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { onStillWorking() }
        }
        defer { timer.cancel() }
        return try await orchestrator.answer(question: question)
    }
}
