import Foundation
import Observation
import Core
import Data
import Goals
import DailyLoop

/// # VoiceCaptureController — voice-first Evening Capture (@MainActor)
///
/// One spoken interaction fills `EveningCapture.CaptureInput` and, on confirmation, applies it —
/// "record once → confirm → applied" for the common case (acceptance criterion). Deterministic
/// parsing (`VoiceCaptureParser`), no LLM.
///
/// Privacy / safety: **nothing persists before confirmation**. The transcript is parsed into a
/// draft held in memory; `EveningCapture.apply(_:now:)` runs only from `confirm(now:)`. The raw
/// transcript is never written to memory — only the confirmed capture's derived `DailyLog` /
/// `GoalProgress` / `OpenLoop` entries are (PRD privacy rule).
@MainActor
@Observable
public final class VoiceCaptureController {

    public enum State: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        /// A parsed draft awaiting the single confirm/cancel. `lowConfidence` flags a shaky
        /// transcript so the UI can warn — but capture always confirms, so nothing writes early.
        case reviewing(summary: String, lowConfidence: Bool)
        case applied(CaptureResult)
        case error(String)
    }

    public private(set) var state: State = .idle
    /// The draft the review step is showing (held in memory only until confirmed).
    public private(set) var draft: VoiceCaptureDraft?

    private let stt: SpeechToText
    private let store: MemoryStore
    private let calendar: Calendar
    private let parser = VoiceCaptureParser()
    private let audio: AudioSessionCoordinating

    public init(stt: SpeechToText,
                store: MemoryStore,
                calendar: Calendar = .current,
                audio: AudioSessionCoordinating = AudioSessionStateMachine()) {
        self.stt = stt
        self.store = store
        self.calendar = calendar
        self.audio = audio
    }

    /// Record one utterance and parse it against the day's open tasks into a reviewable draft.
    /// Persists nothing.
    public func captureTurn(openTasks: [(goal: Goal, task: GoalTask)]) async {
        state = .listening
        do {
            try await audio.activate(.recording)
            let transcript = try await stt.record()
            await audio.deactivate()
            state = .transcribing

            guard !transcript.isEmpty else { state = .idle; return }
            let draft = parser.parse(transcript: transcript.text, openTasks: openTasks)
            self.draft = draft
            state = .reviewing(summary: draft.reviewSummary, lowConfidence: !transcript.isConfident)
        } catch {
            await audio.deactivate()
            fail(error)
        }
    }

    /// The single confirmation: apply the reviewed draft to memory. Only here does anything
    /// persist.
    @discardableResult
    public func confirm(now: Date = Date()) -> CaptureResult? {
        guard case .reviewing = state, let draft else { return nil }
        do {
            let capture = EveningCapture(store: store, calendar: calendar)
            let result = try capture.apply(draft.input, now: now)
            state = .applied(result)
            self.draft = nil
            return result
        } catch {
            fail(error)
            return nil
        }
    }

    /// Discard the draft without writing anything.
    public func cancel() {
        draft = nil
        state = .idle
    }

    private func fail(_ error: Error) {
        let message = (error as? AppError)?.userMessage ?? "Voice capture is temporarily unavailable."
        state = .error(message)
    }
}
