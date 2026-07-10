import Foundation
import SwiftData
import Core
import Data
import Integrations
import Proposals
import Reasoning

/// # AgentEnvironment — composition root for the reasoning layer
///
/// Builds the `ReasoningProvider` (Gemini Flash by default) from the configured API key and
/// wires the narrative workflows + the Q&A orchestrator. Mirrors `IntegrationsEnvironment`'s
/// two-state shape: `.live(apiKey:)` when a key is present, `.unavailable()` when it is not
/// (the app still runs; the Ask surface shows a clear "add your Gemini API key" message rather
/// than crashing — graceful degradation, Safety Rule #6).
///
/// Provider swappability is preserved here: swapping Gemini for another provider is changing the
/// one line that constructs `provider` — nothing above this boundary (prompts, tools, loop,
/// narrators) references Gemini.
@MainActor
public final class AgentEnvironment {
    /// The reasoning provider, or nil when no API key is configured.
    public let provider: (any ReasoningProvider)?
    public let audit: any ModelCallAuditSink
    public let clock: any Clock

    private init(provider: (any ReasoningProvider)?, audit: any ModelCallAuditSink, clock: any Clock) {
        self.provider = provider
        self.audit = audit
        self.clock = clock
    }

    public var isAvailable: Bool { provider != nil }

    /// Live environment backed by Gemini Flash. `transport` is injectable so the app uses the
    /// real `URLSession` while tests drive a mocked transport.
    public static func live(apiKey: String,
                            model: String = GeminiReasoningProvider.defaultModel,
                            transport: HTTPTransport = URLSessionTransport(),
                            audit: any ModelCallAuditSink = LoggingModelCallAuditSink(),
                            clock: any Clock = SystemClock()) -> AgentEnvironment {
        let provider = GeminiReasoningProvider(apiKey: apiKey, model: model, transport: transport)
        return AgentEnvironment(provider: provider, audit: audit, clock: clock)
    }

    /// Build directly from a provider (used by tests to inject a fake/scripted provider, and by
    /// a future provider swap).
    public static func with(provider: any ReasoningProvider,
                            audit: any ModelCallAuditSink = InMemoryModelCallAuditSink(),
                            clock: any Clock = SystemClock()) -> AgentEnvironment {
        AgentEnvironment(provider: provider, audit: audit, clock: clock)
    }

    /// No API key configured — reasoning features are unavailable but the app runs.
    public static func unavailable(clock: any Clock = SystemClock()) -> AgentEnvironment {
        AgentEnvironment(provider: nil, audit: InMemoryModelCallAuditSink(), clock: clock)
    }

    // MARK: - Workflow factories

    public func briefingNarrator() -> BriefingNarrator? {
        provider.map { BriefingNarrator(provider: $0, audit: audit, clock: clock) }
    }

    public func weeklyReviewNarrator() -> WeeklyReviewNarrator? {
        provider.map { WeeklyReviewNarrator(provider: $0, audit: audit, clock: clock) }
    }

    /// Build a Q&A orchestrator bound to a live `ModelContext` and the current integration seams.
    /// The propose tools enqueue through a `ProposalEngine` built over the same context (Phase 4A).
    public func qaOrchestrator(context: ModelContext,
                               calendar: (any GoogleCalendarAPI)? = nil,
                               gmail: (any GmailAPI)? = nil,
                               health: (any HealthKitDataSource)? = nil) -> QAOrchestrator? {
        guard let provider else { return nil }
        let engine = ProposalEngine(context: context, clock: clock, calendar: calendar)
        let toolContext = ToolContext(context: context, clock: clock, calendar: calendar,
                                      gmail: gmail, health: health, engine: engine)
        return QAOrchestrator(provider: provider, ctx: toolContext, audit: audit)
    }
}
