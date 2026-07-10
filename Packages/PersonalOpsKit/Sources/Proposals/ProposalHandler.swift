import Foundation
import SwiftData
import Core
import Data
import Integrations

/// Errors the proposal state machine and handlers can raise.
public enum ProposalError: Error, Equatable {
    /// A transition (approve/dismiss/snooze/…) was attempted from a non-`pending` status.
    case notPending(ProposalStatus)
    /// Approval was attempted on a proposal already past its expiry — it is dropped, never run.
    case expired
    /// No handler is registered for the proposal's type (should be impossible — all types covered).
    case noHandler(ProposalType)
    /// A calendar handler ran while the calendar integration was unavailable (unconfigured /
    /// disconnected). Surfaced to the user; the proposal stays pending so it can be retried.
    case integrationUnavailable
    /// The object a handler targets (a `GoalTask`/`OpenLoop`) was not found in the store.
    case targetNotFound
    /// The proposal's payload could not be decoded into its type's payload struct.
    case malformedPayload
}

/// A receipt returned by a handler — proof that exactly one described action ran, and a
/// human-readable summary for the Inbox. Carries no capability; it is an after-the-fact record.
public struct ExecutionReceipt: Equatable, Sendable {
    public let proposalAppID: UUID
    public let type: ProposalType
    public let summary: String
    /// Set by the create-event handler — the ID of the (idempotently) created agent event.
    public let createdEventID: String?

    public init(proposalAppID: UUID, type: ProposalType, summary: String, createdEventID: String? = nil) {
        self.proposalAppID = proposalAppID
        self.type = type
        self.summary = summary
        self.createdEventID = createdEventID
    }
}

/// Everything a handler needs to perform its one action. Holds the `ModelContext` (handlers
/// build a `MemoryStore` from it for append-only writes, and mutate structural `GoalTask`s
/// directly), the injected `Clock`, and the optional agent-calendar API. Not `Sendable` — it
/// carries a `ModelContext`, so it (like the engine) is used on the context's owning actor.
public struct HandlerContext {
    public let context: ModelContext
    public let clock: any Clock
    public let calendar: (any GoogleCalendarAPI)?

    public init(context: ModelContext, clock: any Clock, calendar: (any GoogleCalendarAPI)?) {
        self.context = context
        self.clock = clock
        self.calendar = calendar
    }

    /// Convenience: an append-only store over the same context/clock.
    public var store: MemoryStore { MemoryStore(context: context, clock: clock) }

    /// Fetch a persisted model by its stable `appID` (post-fetch filter — a generic
    /// `#Predicate` over `appID` across model types is not worth the ceremony at single-user
    /// scale, consistent with `MemoryStore`).
    public func fetch<T: PersistentModel>(_ type: T.Type, appID: UUID,
                                          keyPath: (T) -> UUID) throws -> T? {
        try context.fetch(FetchDescriptor<T>()).first { keyPath($0) == appID }
    }
}

/// # ProposalHandler — one action, nothing else
///
/// Each `ProposalType` has exactly one handler. The whole safety model rests on two facts:
///  1. A handler can only run when handed an `ApprovalGrant`, and **only `ProposalEngine`
///     can mint one** (its initializer is file-private to the engine, constructed solely
///     inside `approve(...)`). No test, tool, or view can construct a grant, so no handler
///     is callable except through an approved `pending → approved` transition.
///  2. `execute` performs *only* its type's action and returns a receipt — never an inferred
///     follow-up (the engine dispatches to a single handler, never chains).
///
/// `@MainActor` because handlers touch the (main-actor) `ModelContext`; calendar calls are
/// `await` and hop off the main actor and back, carrying only `Sendable` DTOs.
@MainActor
public protocol ProposalHandler {
    /// The single type this handler executes. The engine registers handlers by this key.
    var handledType: ProposalType { get }

    /// Perform this proposal's one action. The `grant` proves the engine approved a pending
    /// proposal; without it the call does not compile.
    func execute(_ proposal: Proposal, grant: ApprovalGrant, context: HandlerContext) async throws -> ExecutionReceipt
}
