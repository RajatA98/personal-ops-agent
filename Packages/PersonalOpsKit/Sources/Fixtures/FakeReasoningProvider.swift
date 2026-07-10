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

    public var providerName: String { "fake" }

    public var recordedRequests: [ReasoningRequest] {
        lock.withLock { _recordedRequests }
    }

    public func complete(_ request: ReasoningRequest) async throws -> ReasoningResponse {
        lock.withLock { _recordedRequests.append(request) }
        return ReasoningResponse(text: scriptedText, toolCalls: scriptedToolCalls)
    }
}

/// A `ReasoningProvider` that replays a **scripted sequence** of responses, one per call — the
/// "scripted-response test harness" Phase 5's golden fixtures need to drive the bounded loop
/// deterministically (e.g. round 1 returns a tool call, round 2 returns the final answer). It
/// records every request so tests can assert the transcript that was built, the tools that were
/// offered, and the tool-choice on the forced-answer round. Once the script is exhausted it
/// returns the `fallback` (default: an empty final answer), so a loop can never hang on it.
public final class ScriptedReasoningProvider: ReasoningProvider, @unchecked Sendable {

    private let lock = NSLock()
    private var remaining: [ReasoningResponse]
    private let fallback: ReasoningResponse
    private var _recordedRequests: [ReasoningRequest] = []
    public let providerName: String

    public init(script: [ReasoningResponse],
                fallback: ReasoningResponse = ReasoningResponse(text: ""),
                providerName: String = "scripted") {
        self.remaining = script
        self.fallback = fallback
        self.providerName = providerName
    }

    public var recordedRequests: [ReasoningRequest] {
        lock.withLock { _recordedRequests }
    }

    /// Number of times `complete` was called (== rounds the loop ran).
    public var callCount: Int {
        lock.withLock { _recordedRequests.count }
    }

    public func complete(_ request: ReasoningRequest) async throws -> ReasoningResponse {
        lock.withLock {
            _recordedRequests.append(request)
            if remaining.isEmpty { return fallback }
            return remaining.removeFirst()
        }
    }
}
