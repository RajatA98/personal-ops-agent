import Foundation

/// # TextToSpeech — the playback boundary
///
/// A provider-swappable abstraction over spoken playback. Two implementations exist:
/// `ElevenLabsTTS` (cloud REST, higher voice quality — LOCKED_DECISIONS #7's primary) and
/// `SystemTTS` (`AVSpeechSynthesizer`, the offline fallback). `TTSRouter` picks between them.
///
/// Playback is **interruptible**: `speak(_:)` runs until the utterance finishes *or* `stop()` is
/// called, whichever comes first. `stop()` must halt audio immediately (the interruption
/// acceptance criterion) — implementations make their in-flight `speak(_:)` return promptly.
public protocol TextToSpeech: Sendable {
    /// Speak `text`, returning when playback completes (or is stopped). Throws on failure so a
    /// router can fall back to another provider.
    func speak(_ text: String) async throws

    /// Halt any in-progress playback immediately.
    func stop() async
}
