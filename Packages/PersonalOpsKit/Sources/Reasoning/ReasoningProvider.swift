import Foundation
import Core

/// The swappable LLM reasoning boundary (LOCKED_DECISIONS #6 — Gemini Flash default,
/// provider swap is a config change). This is the *abstraction only*; the Gemini
/// implementation and the read/propose tool split land in Phase 5. Message formatting
/// lives behind this protocol so prompts stay provider-agnostic (AGENT_DESIGN §5).
public struct ReasoningMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case system, user, assistant, tool
    }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// A tool call requested by the model. In Phase 5 the harness classifies each as read
/// (execute now) or propose (queue a Proposal) — never a direct state mutation.
public struct ReasoningToolCall: Equatable, Sendable {
    public let name: String
    public let argumentsJSON: String

    public init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ReasoningRequest: Equatable, Sendable {
    public let purpose: ModelCallAudit.Purpose
    public let messages: [ReasoningMessage]

    public init(purpose: ModelCallAudit.Purpose, messages: [ReasoningMessage]) {
        self.purpose = purpose
        self.messages = messages
    }
}

public struct ReasoningResponse: Equatable, Sendable {
    public let text: String?
    public let toolCalls: [ReasoningToolCall]

    public init(text: String?, toolCalls: [ReasoningToolCall] = []) {
        self.text = text
        self.toolCalls = toolCalls
    }
}

public protocol ReasoningProvider: Sendable {
    func complete(_ request: ReasoningRequest) async throws -> ReasoningResponse
}
