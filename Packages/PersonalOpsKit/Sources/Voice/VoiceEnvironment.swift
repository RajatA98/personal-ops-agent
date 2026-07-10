import Foundation
import Core
import Data
import Integrations
import Agent

/// # VoiceEnvironment — composition root for the voice stack
///
/// Builds the STT (Apple Speech) and the TTS router (ElevenLabs-first when a real
/// `ELEVENLABS_API_KEY` is configured, else `AVSpeechSynthesizer`-only) and hands out the two
/// conversational controllers. Mirrors `AgentEnvironment` / `IntegrationsEnvironment`: it always
/// yields a working environment (degrade gracefully — Safety Rule #6). With no ElevenLabs key the
/// system voice is used; STT still works on-device.
@MainActor
public final class VoiceEnvironment {

    public let stt: SpeechToText
    /// True when ElevenLabs is the primary voice (a real key is configured); false when routing
    /// straight to the system voice.
    public let usesCloudVoice: Bool

    private let makeTTS: @MainActor () -> TextToSpeech
    private let makeAudio: @MainActor () -> AudioSessionCoordinating

    private init(stt: SpeechToText,
                 usesCloudVoice: Bool,
                 makeTTS: @escaping @MainActor () -> TextToSpeech,
                 makeAudio: @escaping @MainActor () -> AudioSessionCoordinating) {
        self.stt = stt
        self.usesCloudVoice = usesCloudVoice
        self.makeTTS = makeTTS
        self.makeAudio = makeAudio
    }

    /// Live environment. `elevenLabsAPIKey` is used only if it's a real (non-placeholder) key;
    /// otherwise the router runs the system voice. `transport` is injectable so tests drive a
    /// mocked ElevenLabs transport.
    public static func live(elevenLabsAPIKey: String?,
                            transport: HTTPTransport = URLSessionTransport()) -> VoiceEnvironment {
        let stt = AppleSpeechToText()
        let audio: @MainActor () -> AudioSessionCoordinating = {
            #if canImport(AVFoundation) && os(iOS)
            return iOSAudioSessionCoordinator()
            #else
            return AudioSessionStateMachine()
            #endif
        }
        if let key = elevenLabsAPIKey, isRealKey(key) {
            return VoiceEnvironment(
                stt: stt, usesCloudVoice: true,
                makeTTS: { TTSRouter(primary: ElevenLabsTTS(apiKey: key, transport: transport),
                                     fallback: SystemTTS(), primaryHealthy: true) },
                makeAudio: audio)
        }
        return VoiceEnvironment(
            stt: stt, usesCloudVoice: false,
            makeTTS: { TTSRouter(primary: SystemTTS(), fallback: SystemTTS(), primaryHealthy: false) },
            makeAudio: audio)
    }

    /// Inject fakes (tests/previews).
    public static func with(stt: SpeechToText,
                            makeTTS: @escaping @MainActor () -> TextToSpeech,
                            usesCloudVoice: Bool = false,
                            makeAudio: @escaping @MainActor () -> AudioSessionCoordinating = { AudioSessionStateMachine() }) -> VoiceEnvironment {
        VoiceEnvironment(stt: stt, usesCloudVoice: usesCloudVoice, makeTTS: makeTTS, makeAudio: makeAudio)
    }

    // MARK: - Controller factories

    /// A push-to-talk Q&A conversation controller wrapping the given orchestrator.
    public func conversationController(orchestrator: QAOrchestrator,
                                       stillWorkingAfter: Duration = .seconds(4)) -> VoiceConversationController {
        let responder = OrchestratorQAResponder(orchestrator: orchestrator, stillWorkingAfter: stillWorkingAfter)
        return VoiceConversationController(stt: stt, tts: makeTTS(), responder: responder, audio: makeAudio())
    }

    /// A voice-first Evening Capture controller writing through the given memory store.
    public func captureController(store: MemoryStore, calendar: Calendar = .current) -> VoiceCaptureController {
        VoiceCaptureController(stt: stt, store: store, calendar: calendar, audio: makeAudio())
    }

    private static func isRealKey(_ key: String) -> Bool {
        !key.isEmpty && !key.hasPrefix("REPLACE_ME")
    }
}
