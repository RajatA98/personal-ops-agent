import Foundation
import Core
import Integrations

/// # GeminiReasoningProvider — the ONLY Gemini-specific code in the reasoning stack
///
/// Implements the provider-neutral `ReasoningProvider` against Google's Generative Language
/// REST API (`generateContent` with function-calling). Everything Gemini-shaped lives here:
/// the request body (`systemInstruction`/`contents`/`tools`/`toolConfig`), the function-call
/// response parsing, and the HTTP→`AppError` mapping. The prompts, tool registry, and bounded
/// loop above this boundary never mention Gemini — so swapping to another provider (Claude,
/// OpenAI) is implementing this one protocol again, a config change, not a rewrite
/// (LOCKED_DECISIONS #6, AGENT_DESIGN §5, Phase 5 risk note).
///
/// Live-capable, mock-verified: the request-building and response-parsing paths are exercised
/// by `MockURLProtocol` transport tests without hitting the network (Phase 2's pattern). Only a
/// real `GEMINI_API_KEY` can verify the live consent/quota behavior.
///
/// The API key is placed in the request URL's `key` query item (Gemini's convention) and is
/// **never logged** — this type performs no logging, and `RedactingLogger` scrubs `AIza…` keys
/// as a backstop (Safety Rule #5). No streaming in v1.
public struct GeminiReasoningProvider: ReasoningProvider {

    /// Default model — "Gemini Flash" per LOCKED_DECISIONS #6. Swappable via `init(model:)`.
    public static let defaultModel = "gemini-2.0-flash"

    private let apiKey: String
    private let model: String
    private let transport: HTTPTransport
    private let baseURL: URL
    private let retryPolicy: RetryPolicy

    public init(apiKey: String,
                model: String = GeminiReasoningProvider.defaultModel,
                transport: HTTPTransport = URLSessionTransport(),
                baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
                retryPolicy: RetryPolicy = .standard) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.baseURL = baseURL
        self.retryPolicy = retryPolicy
    }

    /// Provider identity for the audit log — the model name only, never the key.
    public var providerName: String { "gemini:\(model)" }

    public func complete(_ request: ReasoningRequest) async throws -> ReasoningResponse {
        let body = Self.requestBody(for: request)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1beta/models/\(model):generateContent"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var mutableRequest = URLRequest(url: components.url!)
        mutableRequest.httpMethod = "POST"
        mutableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mutableRequest.httpBody = data
        let urlRequest = mutableRequest

        let responseData = try await withRetry(policy: retryPolicy) {
            let (payload, http) = try await transport.send(urlRequest)
            if let error = GeminiErrorMapper.error(for: http.statusCode, body: payload) {
                throw error
            }
            return payload
        }

        return try Self.parseResponse(responseData)
    }

    // MARK: - Request shaping (Gemini-specific)

    /// Build the Gemini `generateContent` request body from the neutral request.
    static func requestBody(for request: ReasoningRequest) -> [String: Any] {
        var body: [String: Any] = [:]

        // System messages → a single systemInstruction.
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemText]]]
        }

        // Non-system messages → contents.
        var contents: [[String: Any]] = []
        for message in request.messages where message.role != .system {
            switch message.role {
            case .user:
                contents.append(["role": "user", "parts": [["text": message.content]]])
            case .assistant:
                var parts: [[String: Any]] = []
                if !message.content.isEmpty {
                    parts.append(["text": message.content])
                }
                for call in message.toolCalls {
                    parts.append(["functionCall": ["name": call.name, "args": call.arguments]])
                }
                if parts.isEmpty { parts.append(["text": ""]) }
                contents.append(["role": "model", "parts": parts])
            case .tool:
                // Gemini carries a tool result as a user-role functionResponse.
                let responseObject = Self.toolResponseObject(from: message.content)
                contents.append([
                    "role": "user",
                    "parts": [["functionResponse": [
                        "name": message.toolName ?? "",
                        "response": responseObject
                    ]]]
                ])
            case .system:
                break
            }
        }
        body["contents"] = contents

        // Tools → functionDeclarations.
        if !request.tools.isEmpty {
            let declarations: [[String: Any]] = request.tools.map { tool in
                var declaration: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description
                ]
                if let schema = Self.jsonObject(from: tool.parametersSchema) {
                    declaration["parameters"] = schema
                }
                return declaration
            }
            body["tools"] = [["functionDeclarations": declarations]]
            body["toolConfig"] = [
                "functionCallingConfig": ["mode": request.toolChoice == .none ? "NONE" : "AUTO"]
            ]
        }

        return body
    }

    /// Gemini's `functionResponse.response` must be a JSON object. If the tool returned a JSON
    /// object, pass it through; otherwise wrap the raw string under `content`.
    private static func toolResponseObject(from content: String) -> [String: Any] {
        if let object = jsonObject(from: content) { return object }
        return ["content": content]
    }

    private static func jsonObject(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    // MARK: - Response parsing (Gemini-specific)

    /// Parse a `generateContent` response into the neutral `ReasoningResponse`. Collects every
    /// `functionCall` part into tool calls and joins `text` parts into the answer.
    static func parseResponse(_ data: Data) throws -> ReasoningResponse {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.reasoning(.invalidResponse)
        }
        guard let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            // No candidate content (e.g. a safety block or empty completion).
            throw AppError.reasoning(.invalidResponse)
        }

        var texts: [String] = []
        var toolCalls: [ReasoningToolCall] = []
        for part in parts {
            if let text = part["text"] as? String {
                texts.append(text)
            } else if let call = part["functionCall"] as? [String: Any],
                      let name = call["name"] as? String {
                let args = call["args"] as? [String: Any] ?? [:]
                let argsJSON = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append(ReasoningToolCall(name: name, argumentsJSON: argsJSON))
            }
        }

        let joined = texts.joined()
        return ReasoningResponse(text: joined.isEmpty ? nil : joined, toolCalls: toolCalls)
    }
}

/// Maps a Gemini HTTP status to a typed `AppError`. Kept separate (and Gemini-scoped) so the
/// mapping is unit-testable and the provider stays focused on request/response shaping.
public enum GeminiErrorMapper {
    /// Returns `nil` for a success (2xx) status; otherwise the mapped error.
    public static func error(for status: Int, body: Data?) -> AppError? {
        switch status {
        case 200...299:
            return nil
        case 400:
            // Malformed request (or a malformed/invalid key value) — not retryable.
            return .reasoning(.invalidResponse)
        case 401, 403:
            // Missing / rejected key — a configuration problem the user must fix; never retried.
            return .configuration(.missingKey(Config.Key.geminiAPIKey.rawValue))
        case 429:
            // Quota / rate limit — retryable via the standard policy.
            return .integration(.rateLimited(source: .reasoning))
        case 500...599:
            return .reasoning(.providerUnavailable)
        default:
            return .network(.httpStatus(status))
        }
    }
}
