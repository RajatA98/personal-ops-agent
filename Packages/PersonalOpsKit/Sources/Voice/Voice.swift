import Foundation
import Core

/// # Voice module (Phase 6)
///
/// The conversational voice interface, layered on top of the finished text/data loop. Two
/// concerns live here:
///
/// **Plumbing** (provider-swappable, low-level; imports only Core + platform frameworks):
///   - `SpeechToText` — on-device transcription (Apple Speech) with per-utterance confidence.
///   - `TextToSpeech` — `ElevenLabsTTS` (REST) with a `SystemTTS` (`AVSpeechSynthesizer`)
///     fallback, routed by `TTSRouter`. Playback is interruptible.
///   - `AudioSessionCoordinating` — record/playback handoff (iOS-guarded, host-testable state).
///
/// **Conversation** (wraps the Q&A loop, AGENT_DESIGN §1):
///   - `VoiceConversationController` — push-to-talk turn flow (record → transcribe → route →
///     speak), low-confidence confirmation before any Proposal/memory write, interruptible TTS.
///   - `VoiceCaptureController` + `VoiceCaptureParser` — voice-first Evening Capture that fills
///     `EveningCapture.CaptureInput` deterministically, with a review/confirm step.
///
/// Privacy: transcripts are NOT stored as memory by default — only a confirmed capture or an
/// approved Proposal ever persists derived data (PRD rule, enforced here).
public enum VoiceModule {

    /// Transcriptions whose confidence is at or below this threshold require **explicit user
    /// confirmation** before they are sent to the reasoning model or turned into a Proposal /
    /// memory entry (acceptance criterion; PRD "low-confidence transcriptions require
    /// confirmation").
    ///
    /// **Chosen: 0.6.** Rationale: Apple's `SFTranscriptionSegment.confidence` is a 0…1 score
    /// where dictation-grade segments cluster high (≥ 0.8) and genuine mis-hears fall well below
    /// 0.5. 0.6 sits in the gap: it lets a clean utterance flow straight through (no nagging on
    /// good speech, which would kill the "feels good to talk to" goal) while still catching the
    /// noisy/garbled transcripts that would otherwise create a wrong Proposal or memory fact. It
    /// is deliberately on the cautious side of the midpoint because the cost of a wrong write
    /// (Safety Rules #1/#3) outweighs the cost of one extra confirmation tap.
    public static let lowConfidenceThreshold = 0.6

    /// The design budget for how quickly interrupting playback must take effect: from the moment
    /// the user requests a stop, audio must halt within this window. Enforced structurally by
    /// `TTSRouter.stop()` flipping playback state **synchronously** and halting the active
    /// provider immediately (the state-machine tests assert the synchronous transition against a
    /// fake audio layer). Real end-to-end audio latency on device is device-verified.
    public static let interruptionLatencyTarget: Duration = .milliseconds(100)
}
