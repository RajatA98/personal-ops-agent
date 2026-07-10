import Foundation
import Core

/// # Voice module
///
/// Phase 6 fills this in: on-device STT (Apple Speech) for capture, ElevenLabs TTS with a
/// swappable `AVSpeechSynthesizer` fallback, turn-taking conversation, interruptible
/// playback, and low-confidence-transcript confirmation before any Proposal/memory write.
/// Phase 0 fixes the provider-swap boundary so the ElevenLabs → fallback switch is config.
public protocol SpeechSynthesizer: Sendable {
    func speak(_ text: String) async throws
    func stop() async
}

public enum VoiceModule {
    public static let lowConfidenceThreshold = 0.6
}
