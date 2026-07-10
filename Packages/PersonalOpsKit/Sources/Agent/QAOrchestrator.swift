import Foundation
import Core
import Data
import Goals
import Reasoning

/// The result of one Q&A turn.
public struct QAResult: Equatable, Sendable {
    /// The model's final answer.
    public let answer: String
    /// How many model calls (rounds) it took, including the forced-answer round if reached.
    public let rounds: Int
    /// Names of tools the model actually invoked across the turn.
    public let usedTools: [String]
    /// True if the round budget was exhausted and the answer came from the forced (`tool_choice
    /// none`) round.
    public let forcedAnswer: Bool

    public init(answer: String, rounds: Int, usedTools: [String], forcedAnswer: Bool) {
        self.answer = answer
        self.rounds = rounds
        self.usedTools = usedTools
        self.forcedAnswer = forcedAnswer
    }
}

/// # QAOrchestrator — the bounded native tool-calling loop (AGENT_DESIGN §2)
///
/// The ONLY agentic flow (§1): free-form Q&A over memory. It runs a ReAct-shaped loop using
/// native function calling — up to `maxToolRounds` tool-executing rounds, then a forced answer
/// (`tool_choice: none`, "answer with what you have"). Read tool calls execute immediately;
/// propose tool calls create a pending Proposal and return a receipt. Every round is logged to
/// the model-call audit (metadata + tool names/args; never tokens/headers).
///
/// Provider-neutral by construction: it speaks only the `ReasoningProvider` protocol and the
/// neutral tool/message types, so the Gemini→any swap is a config change. Phase 6's voice wraps
/// this exact seam (STT → `answer(question:)` → TTS).
///
/// `@MainActor` because the tools drive the SwiftData context / `@MainActor ProposalEngine`.
@MainActor
public struct QAOrchestrator {
    private let provider: any ReasoningProvider
    private let registry: ToolRegistry
    private let ctx: ToolContext
    private let audit: any ModelCallAuditSink
    private let maxToolRounds: Int

    public init(provider: any ReasoningProvider,
                ctx: ToolContext,
                audit: any ModelCallAuditSink = InMemoryModelCallAuditSink(),
                maxToolRounds: Int = 5) {
        self.provider = provider
        self.registry = ToolRegistry(ctx: ctx)
        self.ctx = ctx
        self.audit = audit
        self.maxToolRounds = maxToolRounds
    }

    /// The system prompt = shared preamble + Q&A instructions (AGENT_DESIGN §5).
    private var systemPrompt: String {
        PromptLibrary.load(.sharedPreamble).body + "\n\n---\n\n" + PromptLibrary.load(.qaSystem).body
    }

    /// A tiny memory digest injected into the preamble (§4: goal titles + today's headline;
    /// everything else the model fetches via read tools). Kept compact to hold the ~1.5k budget.
    public func preambleDigest() -> String {
        let now = ctx.clock.now
        let goals = (try? ctx.store.all(Goal.self)) ?? []
        let titles = goals.filter { $0.isActive(asOf: now) && $0.status == .active }.map(\.title)
        if titles.isEmpty {
            return "Context: no active goals on record. Use tools to look up anything else."
        }
        return "Context: active goals — \(titles.joined(separator: "; ")). Use tools for details."
    }

    /// Build the initial transcript for a question.
    public func initialMessages(question: String) -> [ReasoningMessage] {
        [
            ReasoningMessage(role: .system, content: systemPrompt),
            ReasoningMessage(role: .system, content: preambleDigest()),
            ReasoningMessage(role: .user, content: question)
        ]
    }

    public func answer(question: String) async throws -> QAResult {
        var transcript = initialMessages(question: question)
        var usedTools: [String] = []
        var includedExternal = false
        var rounds = 0

        while rounds < maxToolRounds {
            rounds += 1
            let response = try await callModel(transcript, toolChoice: .auto, round: rounds,
                                               includedExternal: includedExternal)

            if response.isFinal {
                return QAResult(answer: response.text ?? "", rounds: rounds,
                                usedTools: usedTools, forcedAnswer: false)
            }

            // Echo the model's tool-call turn into the transcript so the next round has history.
            transcript.append(ReasoningMessage(role: .assistant, content: response.text ?? "",
                                               toolCalls: response.toolCalls))

            for call in response.toolCalls {
                usedTools.append(call.name)
                let (result, _) = await registry.execute(call)
                if call.name == "search_gmail" || call.name == "search_calendar" {
                    includedExternal = true
                }
                transcript.append(.toolResult(name: call.name, content: result))
            }
        }

        // Round budget spent → force an answer with the tools it already has (tool_choice none).
        rounds += 1
        let forced = try await callModel(transcript, toolChoice: .none, round: rounds,
                                         includedExternal: includedExternal)
        return QAResult(answer: forced.text ?? "", rounds: rounds,
                        usedTools: usedTools, forcedAnswer: true)
    }

    // MARK: - One model call + its audit

    private func callModel(_ transcript: [ReasoningMessage],
                           toolChoice: ReasoningToolChoice,
                           round: Int,
                           includedExternal: Bool) async throws -> ReasoningResponse {
        let request = ReasoningRequest(purpose: .qanda, messages: transcript,
                                       tools: registry.declarations, toolChoice: toolChoice)
        let response = try await provider.complete(request)

        // Audit metadata only — tool names + sanitized args; never tokens/headers (Safety Rule #5).
        let toolSummaries = response.toolCalls.map { "\($0.name) \($0.argumentsJSON)" }
        audit.record(ModelCallAudit(
            timestamp: ctx.clock.now,
            purpose: .qanda,
            inputCategories: [.userMessage, .memory],
            provider: provider.providerName,
            includedRawExternalContent: includedExternal,
            toolCallsRequested: toolSummaries,
            roundCount: round))
        return response
    }
}
