import Foundation
import Core

/// # TTSRouter — ElevenLabs-first playback with an `AVSpeechSynthesizer` fallback
///
/// Wraps a primary `TextToSpeech` (ElevenLabs when a real key is configured) and a fallback
/// (`SystemTTS`). `speak(_:)` tries the primary; if it throws — a dead key, a 5xx, no network —
/// the router **falls back to the secondary without breaking the conversation** (acceptance
/// criterion), so the user always hears the answer. Once the primary has failed within a session
/// the router stays on the fallback (`primaryHealthy = false`) to avoid re-paying the failing
/// call every turn; `resetHealth()` re-arms it.
///
/// **Interruptible playback state machine** (the other acceptance criterion): `state` moves
/// `idle → speaking → idle`. `stop()` flips the state to `idle` **synchronously** and halts the
/// active provider immediately, so interruption takes effect within
/// `VoiceModule.interruptionLatencyTarget` (asserted against a fake audio layer). A `stop()` mid
/// `speak(_:)` makes that `speak(_:)` return promptly (the provider's own `stop()` unblocks it).
@MainActor
public final class TTSRouter: TextToSpeech {

    public enum PlaybackState: Equatable, Sendable {
        case idle
        case speaking
    }

    private let primary: TextToSpeech
    private let fallback: TextToSpeech

    public private(set) var state: PlaybackState = .idle
    /// Whether the primary provider is currently trusted. Flips false after a failure so the
    /// router doesn't re-attempt a known-bad primary every turn; `resetHealth()` re-arms it.
    public private(set) var primaryHealthy: Bool
    /// True when the last `speak(_:)` was served by the fallback (surfaced for UI/telemetry).
    public private(set) var lastUsedFallback = false

    /// Which provider the current playback is running on, so `stop()` halts the right one.
    private var active: TextToSpeech?

    /// - Parameter primaryHealthy: start trusting the primary (true when a real ElevenLabs key is
    ///   present). When there is no key, pass `false` to route straight to the fallback.
    public init(primary: TextToSpeech, fallback: TextToSpeech, primaryHealthy: Bool = true) {
        self.primary = primary
        self.fallback = fallback
        self.primaryHealthy = primaryHealthy
    }

    public func speak(_ text: String) async throws {
        state = .speaking
        defer { if state == .speaking { state = .idle }; active = nil }

        if primaryHealthy {
            do {
                active = primary
                try await primary.speak(text)
                lastUsedFallback = false
                return
            } catch is CancellationError {
                return    // user interrupted — not a provider failure
            } catch {
                // Primary failed → degrade to the fallback so the conversation continues.
                primaryHealthy = false
                if state != .speaking { return }   // stopped during the failed primary attempt
            }
        }

        active = fallback
        try await fallback.speak(text)
        lastUsedFallback = true
    }

    public func stop() async {
        // Synchronous state flip = the interruption is observable within the latency target
        // regardless of how long the provider takes to physically silence the speaker.
        state = .idle
        let provider = active
        active = nil
        await provider?.stop()
    }

    /// Re-arm the primary provider (e.g. after reconnecting / a new session).
    public func resetHealth() { primaryHealthy = true }
}
