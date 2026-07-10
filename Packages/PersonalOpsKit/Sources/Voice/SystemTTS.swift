import Foundation
import Core

/// # SystemTTS — the offline fallback voice (`AVSpeechSynthesizer`)
///
/// LOCKED_DECISIONS #7's swappable fallback: sounds more synthetic than ElevenLabs but is free,
/// offline, and always available — so a conversation never *breaks* when ElevenLabs fails
/// (acceptance criterion). `TTSRouter` routes here when there's no ElevenLabs key or a cloud call
/// fails. Guarded so the host build stays green; real speech output is device-verified.
#if canImport(AVFoundation)
import AVFoundation

public final class SystemTTS: NSObject, TextToSpeech, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            synthesizer.speak(utterance)
        }
    }

    public func stop() async {
        synthesizer.stopSpeaking(at: .immediate)
        resume()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  didFinish utterance: AVSpeechUtterance) {
        resume()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  didCancel utterance: AVSpeechUtterance) {
        resume()
    }

    private func resume() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}
#else
public final class SystemTTS: TextToSpeech, @unchecked Sendable {
    public init() {}
    public func speak(_ text: String) async throws {}
    public func stop() async {}
}
#endif
