import Foundation
import Core
import Reasoning

/// Protocol-based fake for `ReasoningProvider`. Returns a scripted, deterministic response
/// and records requests so Phase 5's golden fixtures (grounding, honest-ignorance,
/// tool-discipline, propose-containment) can assert against a stable contract without a
/// live model. The real Gemini Flash implementation lands in Phase 5.
public final class FakeReasoningProvider: ReasoningProvider, @unchecked Sendable {

    private let lock = NSLock()
    private let scriptedText: String?
    private let scriptedToolCalls: [ReasoningToolCall]
    private var _recordedRequests: [ReasoningRequest] = []

    public init(scriptedText: String?, scriptedToolCalls: [ReasoningToolCall] = []) {
        self.scriptedText = scriptedText
        self.scriptedToolCalls = scriptedToolCalls
    }

    public var recordedRequests: [ReasoningRequest] {
        lock.withLock { _recordedRequests }
    }

    public func complete(_ request: ReasoningRequest) async throws -> ReasoningResponse {
        lock.withLock { _recordedRequests.append(request) }
        return ReasoningResponse(text: scriptedText, toolCalls: scriptedToolCalls)
    }
}
