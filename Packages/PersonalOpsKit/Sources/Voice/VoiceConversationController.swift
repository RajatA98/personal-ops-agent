import Foundation
import Observation
import Core
import Agent

/// # VoiceConversationController — push-to-talk turn flow (AGENT_DESIGN §1)
///
/// Drives one voice Q&A turn: **record → transcribe → (confirm if low-confidence) → route to the
/// Q&A loop → speak**, with the user able to interrupt playback at any time. `@MainActor` because
/// it drives the `@MainActor QAOrchestrator` (via `VoiceQAResponding`) and publishes UI state.
///
/// Safety / privacy invariants enforced here:
///   - **Low-confidence gate**: a transcript at/under `VoiceModule.lowConfidenceThreshold` stops
///     at `.confirming` and is *not* sent to the model until `confirm()`; `reject()` discards it.
///   - **No transcript is persisted** — turns are kept in memory for display only; nothing is
///     written to `MemoryStore`. Only a propose tool (→ a *pending* Proposal the user approves)
///     or a confirmed capture ever persists derived data (PRD privacy rule).
///   - **Interruptible playback**: `interrupt()` halts TTS and returns to idle within
///     `VoiceModule.interruptionLatencyTarget`.
@MainActor
@Observable
public final class VoiceConversationController {

    /// The turn state machine.
    public enum State: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        /// Low-confidence transcript awaiting explicit confirm/reject before anything is sent.
        case confirming(Transcription)
        case thinking
        case speaking
        case error(String)
    }

    public private(set) var state: State = .idle
    /// The §2 progress cue, set live while a turn is "still working", cleared once it's answered.
    public private(set) var progressCue: String?
    /// Latch (reset at the start of each answered turn) recording that the "still working" cue
    /// fired during it — surfaced for transparency/tests after the transient `progressCue` clears.
    public private(set) var surfacedStillWorking = false
    /// In-memory, display-only conversation history. NEVER persisted (privacy rule).
    public private(set) var turns: [VoiceTurn] = []
    /// Rounds the last answered turn took (from `QAResult`) — surfaced for transparency.
    public private(set) var lastRounds: Int?

    private let stt: SpeechToText
    private let tts: TextToSpeech
    private let responder: VoiceQAResponding
    private let audio: AudioSessionCoordinating

    public init(stt: SpeechToText,
                tts: TextToSpeech,
                responder: VoiceQAResponding,
                audio: AudioSessionCoordinating = AudioSessionStateMachine()) {
        self.stt = stt
        self.tts = tts
        self.responder = responder
        self.audio = audio
    }

    /// Whether interrupting is currently meaningful (playback in progress).
    public var canInterrupt: Bool { state == .speaking }

    /// One push-to-talk turn: capture an utterance and either confirm-gate it or run it. Returns
    /// when the turn has been spoken (or is parked at `.confirming`, or errored).
    public func takeTurn() async {
        progressCue = nil
        state = .listening
        do {
            try await audio.activate(.recording)
            let transcript = try await stt.record()
            await audio.deactivate()
            state = .transcribing

            guard !transcript.isEmpty else { state = .idle; return }
            turns.append(VoiceTurn(role: .user, text: transcript.text))

            if transcript.isConfident {
                await run(transcript.text)
            } else {
                // Gate: do not send to the model or create anything until the user confirms.
                state = .confirming(transcript)
            }
        } catch {
            await audio.deactivate()
            fail(error)
        }
    }

    /// Approve a parked low-confidence transcript → route it to the Q&A loop.
    public func confirm() async {
        guard case let .confirming(transcript) = state else { return }
        await run(transcript.text)
    }

    /// Reject a parked low-confidence transcript → discard it, persist nothing, return to idle.
    public func reject() {
        guard case let .confirming(transcript) = state else { return }
        // Drop the display turn we optimistically appended; nothing was ever sent or stored.
        if turns.last?.text == transcript.text, turns.last?.role == .user {
            turns.removeLast()
        }
        state = .idle
    }

    /// Interrupt in-progress playback → halt audio, return to idle (interruptible acceptance
    /// criterion). Safe to call any time; a no-op when not speaking.
    public func interrupt() async {
        await tts.stop()
        if state == .speaking { state = .idle }
    }

    // MARK: - Internals

    private func run(_ question: String) async {
        state = .thinking
        progressCue = nil
        surfacedStillWorking = false
        do {
            let result = try await responder.answer(question: question) { [weak self] in
                self?.progressCue = "Still working…"
                self?.surfacedStillWorking = true
            }
            lastRounds = result.rounds
            let answer = result.answer.isEmpty ? "I don't have an answer for that." : result.answer
            turns.append(VoiceTurn(role: .assistant, text: answer))

            state = .speaking
            progressCue = nil
            try await audio.activate(.playback)
            try await tts.speak(answer)
            await audio.deactivate()
            if state == .speaking { state = .idle }
        } catch {
            await audio.deactivate()
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        progressCue = nil
        let message: String
        if let appError = error as? AppError {
            message = appError.userMessage
        } else {
            message = "Voice is temporarily unavailable."
        }
        state = .error(message)
    }
}

/// A single spoken exchange, kept in memory for display only (never written to memory).
public struct VoiceTurn: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public let id = UUID()
    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}
