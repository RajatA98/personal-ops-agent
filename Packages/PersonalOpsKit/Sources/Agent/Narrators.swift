import Foundation
import Core
import DailyLoop
import Reasoning

/// # Deterministic single-call narrative workflows (AGENT_DESIGN §1)
///
/// Morning Briefing and Weekly Review are NOT agentic — Swift assembles the context
/// deterministically (Phase 3B's `MorningBriefing` / `WeeklyReview`), and the model makes
/// exactly ONE call to turn that structured value into prose. The model never fetches its own
/// data here, so there are no tools and no loop. The grounding + honesty rules live in the
/// prompts (§5); the golden fixtures assert the model references only provided facts and
/// acknowledges absent sources.
///
/// Provider-neutral: these talk only to the `ReasoningProvider` protocol.

/// Shared assembly for the two single-call narrators.
enum NarrativePrompt {
    /// System prompt = shared preamble + the flow-specific instructions.
    static func system(_ flow: PromptLibrary.Prompt) -> String {
        let preamble = PromptLibrary.load(.sharedPreamble).body
        let instructions = PromptLibrary.load(flow).body
        return preamble + "\n\n---\n\n" + instructions
    }
}

/// Turns a deterministically-assembled `MorningBriefing` into a narrative. One LLM call, no
/// tools. Absent sources are present in the injected JSON so the prompt's honesty rule can act
/// on them.
public struct BriefingNarrator: Sendable {
    private let provider: any ReasoningProvider
    private let audit: any ModelCallAuditSink
    private let clock: any Clock

    public init(provider: any ReasoningProvider,
                audit: any ModelCallAuditSink = InMemoryModelCallAuditSink(),
                clock: any Clock = SystemClock()) {
        self.provider = provider
        self.audit = audit
        self.clock = clock
    }

    /// The exact transcript that would be sent — exposed so budget/grounding fixtures can assert
    /// on the assembled context without a live model.
    public func messages(for briefing: MorningBriefing) -> [ReasoningMessage] {
        [
            ReasoningMessage(role: .system, content: NarrativePrompt.system(.morningBriefing)),
            ReasoningMessage(role: .user, content: AgentContext.json(briefing))
        ]
    }

    public func narrate(_ briefing: MorningBriefing) async throws -> String {
        let request = ReasoningRequest(purpose: .morningBriefing, messages: messages(for: briefing))
        let response = try await provider.complete(request)
        audit.record(ModelCallAudit(
            timestamp: clock.now,
            purpose: .morningBriefing,
            inputCategories: [.calendar, .goals, .memory],
            provider: provider.providerName,
            includedRawExternalContent: false,
            toolCallsRequested: [],
            roundCount: 1))
        guard let text = response.text, !text.isEmpty else {
            throw AppError.reasoning(.invalidResponse)
        }
        return text
    }
}

/// Turns a deterministically-assembled `WeeklyReview` into a narrative. One LLM call, no tools.
/// Degraded sources are present in the injected JSON so the prompt can note gaps honestly.
public struct WeeklyReviewNarrator: Sendable {
    private let provider: any ReasoningProvider
    private let audit: any ModelCallAuditSink
    private let clock: any Clock

    public init(provider: any ReasoningProvider,
                audit: any ModelCallAuditSink = InMemoryModelCallAuditSink(),
                clock: any Clock = SystemClock()) {
        self.provider = provider
        self.audit = audit
        self.clock = clock
    }

    public func messages(for review: WeeklyReview) -> [ReasoningMessage] {
        [
            ReasoningMessage(role: .system, content: NarrativePrompt.system(.weeklyReview)),
            ReasoningMessage(role: .user, content: AgentContext.json(review))
        ]
    }

    public func narrate(_ review: WeeklyReview) async throws -> String {
        let request = ReasoningRequest(purpose: .weeklyReview, messages: messages(for: review))
        let response = try await provider.complete(request)
        audit.record(ModelCallAudit(
            timestamp: clock.now,
            purpose: .weeklyReview,
            inputCategories: [.goals, .memory],
            provider: provider.providerName,
            includedRawExternalContent: false,
            toolCallsRequested: [],
            roundCount: 1))
        guard let text = response.text, !text.isEmpty else {
            throw AppError.reasoning(.invalidResponse)
        }
        return text
    }
}
