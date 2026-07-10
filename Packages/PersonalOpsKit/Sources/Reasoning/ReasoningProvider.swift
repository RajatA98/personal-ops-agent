import Foundation
import Core

/// The swappable LLM reasoning boundary (LOCKED_DECISIONS #6 — Gemini Flash default,
/// provider swap is a config change). This file holds the **provider-neutral** contract:
/// messages, tool declarations, tool-choice, requests and responses. The Gemini
/// implementation (`GeminiReasoningProvider`) is the *only* place that knows Gemini's REST /
/// function-calling shape — everything here (and the loop/registry/prompts built on it) speaks
/// this neutral vocabulary so the Gemini→anything swap stays a config change (AGENT_DESIGN §5).

/// One message in a reasoning transcript. `content` is the free text; `toolCalls` carries an
/// assistant turn that requested tools (echoed back into the transcript so the next round has
/// the history); `toolName` binds a `.tool` result back to the call it answers. Keeping all
/// three provider-neutral is what lets a different provider (Claude/OpenAI) map the same turn
/// to its own tool-use/tool-result blocks.
public struct ReasoningMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case system, user, assistant, tool
    }
    public let role: Role
    public let content: String
    /// For an `assistant` turn that requested tools — the calls it made.
    public let toolCalls: [ReasoningToolCall]
    /// For a `tool` turn — the name of the function this message is the result of.
    public let toolName: String?

    public init(role: Role,
                content: String,
                toolCalls: [ReasoningToolCall] = [],
                toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    /// Convenience for a tool-result turn.
    public static func toolResult(name: String, content: String) -> ReasoningMessage {
        ReasoningMessage(role: .tool, content: content, toolName: name)
    }
}

/// A tool call requested by the model. The harness (Phase 5 loop) classifies each as read
/// (execute now) or propose (queue a Proposal) — never a direct state mutation.
public struct ReasoningToolCall: Equatable, Sendable {
    public let name: String
    public let argumentsJSON: String

    public init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// Decode the arguments as a `[String: Any]` bag (empty on malformed/empty input).
    public var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}

/// A provider-neutral tool/function declaration. `parametersSchema` is a JSON-Schema object
/// encoded as a JSON string — each provider translates it into its own function-declaration
/// format. Declaring tools as data (not Gemini types) is what keeps the registry swappable.
public struct ReasoningTool: Equatable, Sendable {
    public let name: String
    public let description: String
    /// JSON-Schema (a JSON object as a string) describing the tool's parameters.
    public let parametersSchema: String

    public init(name: String, description: String, parametersSchema: String) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
    }
}

/// How the model may use tools this round. `.none` is the forced-answer mode the bounded loop
/// uses after its round budget is spent ("answer with what you have", AGENT_DESIGN §2).
public enum ReasoningToolChoice: String, Equatable, Sendable {
    case auto
    case none
}

public struct ReasoningRequest: Equatable, Sendable {
    public let purpose: ModelCallAudit.Purpose
    public let messages: [ReasoningMessage]
    public let tools: [ReasoningTool]
    public let toolChoice: ReasoningToolChoice

    public init(purpose: ModelCallAudit.Purpose,
                messages: [ReasoningMessage],
                tools: [ReasoningTool] = [],
                toolChoice: ReasoningToolChoice = .auto) {
        self.purpose = purpose
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
    }
}

public struct ReasoningResponse: Equatable, Sendable {
    public let text: String?
    public let toolCalls: [ReasoningToolCall]

    public init(text: String?, toolCalls: [ReasoningToolCall] = []) {
        self.text = text
        self.toolCalls = toolCalls
    }

    /// A response is "final" when the model produced an answer and requested no tools.
    public var isFinal: Bool { toolCalls.isEmpty }
}

public protocol ReasoningProvider: Sendable {
    /// A short identifier used in `ModelCallAudit.provider` (never a secret).
    var providerName: String { get }
    func complete(_ request: ReasoningRequest) async throws -> ReasoningResponse
}

public extension ReasoningProvider {
    var providerName: String { "unknown" }
}
