import XCTest
import Core
import Integrations
@testable import Reasoning

/// Mock-verified Gemini transport tests (Phase 5, Phase 2's pattern): exercise the real
/// request-building and response-parsing paths against `MockURLProtocol` — no network, no key.
final class GeminiReasoningProviderTests: XCTestCase {

    override func setUp() { super.setUp(); MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset(); super.tearDown() }

    private func provider() -> GeminiReasoningProvider {
        GeminiReasoningProvider(apiKey: "AIzaTESTKEY0000000000",
                                model: "gemini-2.0-flash",
                                transport: MockURLProtocol.transport(),
                                baseURL: URL(string: "https://gemini.test")!)
    }

    private func respond(_ json: [String: Any], status: Int = 200) {
        MockURLProtocol.handler = { rec in
            let data = try JSONSerialization.data(withJSONObject: json)
            return (.make(rec.url, status), data)
        }
    }

    // MARK: - Request shape

    func test_requestShape_systemInstructionContentsToolsAndToolConfig() async throws {
        respond(["candidates": [["content": ["role": "model", "parts": [["text": "hi"]]]]]])
        let tool = ReasoningTool(name: "search_memory", description: "search",
                                 parametersSchema: #"{"type":"object","properties":{"query":{"type":"string"}}}"#)
        let request = ReasoningRequest(
            purpose: .qanda,
            messages: [
                ReasoningMessage(role: .system, content: "SYSTEM RULES"),
                ReasoningMessage(role: .user, content: "what's up")
            ],
            tools: [tool],
            toolChoice: .auto)

        _ = try await provider().complete(request)

        let rec = try XCTUnwrap(MockURLProtocol.recorded().first)
        XCTAssertEqual(rec.method, "POST")
        // API key rides in the query, never a header/log.
        XCTAssertTrue(rec.url.query?.contains("key=AIzaTESTKEY0000000000") == true)
        XCTAssertTrue(rec.url.path.contains("gemini-2.0-flash:generateContent"))

        let body = try XCTUnwrap(rec.json)
        let sys = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
        let sysParts = try XCTUnwrap(sys["parts"] as? [[String: Any]])
        XCTAssertEqual(sysParts.first?["text"] as? String, "SYSTEM RULES")

        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["role"] as? String, "user")

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let decls = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(decls.first?["name"] as? String, "search_memory")
        XCTAssertNotNil(decls.first?["parameters"])

        let toolConfig = try XCTUnwrap(body["toolConfig"] as? [String: Any])
        let fcc = try XCTUnwrap(toolConfig["functionCallingConfig"] as? [String: Any])
        XCTAssertEqual(fcc["mode"] as? String, "AUTO")
    }

    func test_toolChoiceNone_setsFunctionCallingModeNone() async throws {
        respond(["candidates": [["content": ["role": "model", "parts": [["text": "final"]]]]]])
        let tool = ReasoningTool(name: "t", description: "d", parametersSchema: #"{"type":"object"}"#)
        _ = try await provider().complete(
            ReasoningRequest(purpose: .qanda, messages: [ReasoningMessage(role: .user, content: "x")],
                             tools: [tool], toolChoice: .none))
        let body = try XCTUnwrap(MockURLProtocol.recorded().first?.json)
        let fcc = ((body["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])
        XCTAssertEqual(fcc?["mode"] as? String, "NONE")
    }

    func test_toolResultTurn_mapsToFunctionResponse() async throws {
        respond(["candidates": [["content": ["role": "model", "parts": [["text": "ok"]]]]]])
        let transcript: [ReasoningMessage] = [
            ReasoningMessage(role: .user, content: "q"),
            ReasoningMessage(role: .assistant, content: "",
                             toolCalls: [ReasoningToolCall(name: "search_memory", argumentsJSON: #"{"query":"dentist"}"#)]),
            .toolResult(name: "search_memory", content: #"{"results":[]}"#)
        ]
        _ = try await provider().complete(ReasoningRequest(purpose: .qanda, messages: transcript))

        let body = try XCTUnwrap(MockURLProtocol.recorded().first?.json)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        // user, model(functionCall), user(functionResponse)
        XCTAssertEqual(contents.count, 3)
        let modelParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        XCTAssertNotNil(modelParts.first?["functionCall"])
        let respParts = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        let fr = try XCTUnwrap(respParts.first?["functionResponse"] as? [String: Any])
        XCTAssertEqual(fr["name"] as? String, "search_memory")
        XCTAssertNotNil(fr["response"])
    }

    // MARK: - Response parsing

    func test_parsesFinalText() async throws {
        respond(["candidates": [["content": ["role": "model", "parts": [["text": "Your dentist is Tuesday."]]]]]])
        let response = try await provider().complete(
            ReasoningRequest(purpose: .qanda, messages: [ReasoningMessage(role: .user, content: "q")]))
        XCTAssertEqual(response.text, "Your dentist is Tuesday.")
        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertTrue(response.isFinal)
    }

    func test_parsesFunctionCall() async throws {
        respond(["candidates": [["content": ["role": "model", "parts": [
            ["functionCall": ["name": "search_calendar", "args": ["start": "2026-07-10T00:00:00Z"]]]
        ]]]]])
        let response = try await provider().complete(
            ReasoningRequest(purpose: .qanda, messages: [ReasoningMessage(role: .user, content: "q")]))
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "search_calendar")
        XCTAssertTrue(response.toolCalls.first?.argumentsJSON.contains("2026-07-10") == true)
        XCTAssertFalse(response.isFinal)
    }

    func test_emptyCandidates_throwsInvalidResponse() async throws {
        respond(["candidates": []])
        do {
            _ = try await provider().complete(
                ReasoningRequest(purpose: .qanda, messages: [ReasoningMessage(role: .user, content: "q")]))
            XCTFail("expected throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .reasoning(.invalidResponse))
        }
    }

    // MARK: - Error mapping

    func test_errorMapping() {
        XCTAssertNil(GeminiErrorMapper.error(for: 200, body: nil))
        XCTAssertEqual(GeminiErrorMapper.error(for: 400, body: nil), .reasoning(.invalidResponse))
        XCTAssertEqual(GeminiErrorMapper.error(for: 401, body: nil), .configuration(.missingKey("GEMINI_API_KEY")))
        XCTAssertEqual(GeminiErrorMapper.error(for: 403, body: nil), .configuration(.missingKey("GEMINI_API_KEY")))
        XCTAssertEqual(GeminiErrorMapper.error(for: 429, body: nil), .integration(.rateLimited(source: .reasoning)))
        XCTAssertEqual(GeminiErrorMapper.error(for: 503, body: nil), .reasoning(.providerUnavailable))
    }

    func test_http500_isRetriedThenSurfaces() async throws {
        // Always 500 → provider retries per policy, then throws the mapped error.
        MockURLProtocol.handler = { rec in (.make(rec.url, 500), Data("{}".utf8)) }
        let fastRetry = GeminiReasoningProvider(
            apiKey: "AIzaX0000000000000000", transport: MockURLProtocol.transport(),
            baseURL: URL(string: "https://gemini.test")!,
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, multiplier: 1, jitter: false))
        do {
            _ = try await fastRetry.complete(
                ReasoningRequest(purpose: .qanda, messages: [ReasoningMessage(role: .user, content: "q")]))
            XCTFail("expected throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .reasoning(.providerUnavailable))
        }
        XCTAssertGreaterThanOrEqual(MockURLProtocol.recorded().count, 2)
    }
}
