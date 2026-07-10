import Foundation
import Core
import Integrations

/// # ElevenLabsTTS — cloud text-to-speech over ElevenLabs' REST API
///
/// LOCKED_DECISIONS #7's primary voice: higher quality than `AVSpeechSynthesizer`, which matters
/// for a daily conversational assistant. Fetches encoded audio from
/// `POST /v1/text-to-speech/{voice_id}` (API key in the `xi-api-key` header — **never logged**;
/// `RedactingLogger` scrubs it as a backstop, Safety Rule #5), then plays it through an injected
/// `AudioPlayer`.
///
/// Reuses Phase 2's `HTTPTransport` + `withRetry`, so the request-building / error path is
/// exercised by a `MockURLProtocol`-backed transport in tests (the request shape, a success, and
/// a failure that must trigger the router's fallback). Live audio quality is device-verified.
public struct ElevenLabsTTS: TextToSpeech {

    public static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"   // ElevenLabs "Rachel" default
    public static let defaultModelID = "eleven_multilingual_v2"

    private let apiKey: String
    private let voiceID: String
    private let modelID: String
    private let transport: HTTPTransport
    private let baseURL: URL
    private let player: AudioPlayer
    private let retryPolicy: RetryPolicy

    public init(apiKey: String,
                voiceID: String = ElevenLabsTTS.defaultVoiceID,
                modelID: String = ElevenLabsTTS.defaultModelID,
                transport: HTTPTransport = URLSessionTransport(),
                player: AudioPlayer = SystemAudioPlayer(),
                baseURL: URL = URL(string: "https://api.elevenlabs.io")!,
                retryPolicy: RetryPolicy = .standard) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.modelID = modelID
        self.transport = transport
        self.player = player
        self.baseURL = baseURL
        self.retryPolicy = retryPolicy
    }

    public func speak(_ text: String) async throws {
        let audio = try await fetchAudio(for: text)
        try Task.checkCancellation()
        try await player.play(audio)
    }

    public func stop() async {
        await player.stop()
    }

    /// Build + send the synthesis request, returning the encoded audio bytes. Maps a non-2xx
    /// status to a typed `AppError` (retryable ones retried per policy) so the router can fall
    /// back on failure.
    private func fetchAudio(for text: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("/v1/text-to-speech/\(voiceID)")
        let body: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = payload
        let urlRequest = request

        return try await withRetry(policy: retryPolicy) {
            let (data, http) = try await transport.send(urlRequest)
            if let error = ElevenLabsErrorMapper.error(for: http.statusCode, body: data) {
                throw error
            }
            guard !data.isEmpty else { throw AppError.voice(.ttsFailed) }
            return data
        }
    }
}

/// Maps an ElevenLabs HTTP status to a typed `AppError`. Kept separate + unit-testable.
public enum ElevenLabsErrorMapper {
    public static func error(for status: Int, body: Data?) -> AppError? {
        switch status {
        case 200...299:
            return nil
        case 401, 403:
            // Missing / rejected key — configuration the user must fix; not retried. The router
            // still degrades gracefully to `SystemTTS` on any thrown error.
            return .configuration(.missingKey(Config.Key.elevenLabsAPIKey.rawValue))
        case 429:
            return .integration(.rateLimited(source: .reasoning))
        case 500...599:
            return .voice(.ttsFailed)
        default:
            return .network(.httpStatus(status))
        }
    }
}
