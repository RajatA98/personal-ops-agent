import Foundation
import SwiftData
import Core
import Data
import Integrations

/// # ApprovalGrant — the un-forgeable proof that a proposal was approved
///
/// A handler's `execute` requires one of these, and **only `ProposalEngine.approve(...)` can
/// mint one** — its initializer is `fileprivate` to this file and is called in exactly one
/// place, inside the `pending → approved` transition. Consequences, enforced by the compiler,
/// not by convention:
///   • No view, tool, test, or future Phase-5 code can construct a grant → no handler is
///     callable except through an approved pending proposal.
///   • Phase 5's propose-tools can create `pending` Proposals (via `enqueue`) but can never
///     execute one. AGENT_DESIGN's "a confused model's worst case is a pending Proposal" is
///     therefore a structural guarantee, not a hope.
public struct ApprovalGrant {
    public let proposalAppID: UUID
    fileprivate init(proposalAppID: UUID) { self.proposalAppID = proposalAppID }
}

/// # ProposalEngine — the safety-critical execution core
///
/// Owns the Proposal status state machine and dispatches approvals to per-type handlers.
///
/// ## State machine (only `approved` ever runs a handler)
/// ```
///                approve() ── runs exactly ONE handler ──▶ approved   (terminal)
///               /
///  pending ──── dismiss() / markAsWrong() ─────────────▶ dismissed  (terminal, never runs)
///     ▲  \
///     |   snooze(until:) ─────────────────────────────▶ snoozed     (never runs; can resurface)
///     |        \
///     |         resurfaceDueSnoozed() (asOf ≥ resurface) ▶ pending
///      \
///       expirePendingPastDue() (asOf ≥ expiry) ────────▶ expired     (terminal, DROPPED, never runs)
/// ```
/// Every transition requires the proposal to currently be `pending`; anything else throws
/// `ProposalError.notPending`. Approval additionally refuses an expired proposal (it is
/// dropped, never executed). Approval runs the handler **first**, and only marks the proposal
/// `approved` on success — so a failed calendar write leaves the proposal `pending` to retry,
/// never silently gone (PRD Integration Failure Modes).
///
/// `@MainActor` because it drives a `ModelContext`; calendar handlers `await` off-actor and back.
@MainActor
public final class ProposalEngine {
    private let context: ModelContext
    private let clock: any Clock
    private let calendar: (any GoogleCalendarAPI)?
    private let handlers: [ProposalType: any ProposalHandler]

    /// Construct with an explicit handler set (tests inject spies) or the default full set.
    public init(context: ModelContext,
                clock: any Clock = SystemClock(),
                calendar: (any GoogleCalendarAPI)? = nil,
                handlers: [any ProposalHandler]? = nil) {
        self.context = context
        self.clock = clock
        self.calendar = calendar
        let list = handlers ?? Self.defaultHandlers()
        var map: [ProposalType: any ProposalHandler] = [:]
        for h in list { map[h.handledType] = h }
        self.handlers = map
    }

    /// The full production handler set — one per `ProposalType`.
    public static func defaultHandlers() -> [any ProposalHandler] {
        [
            RememberFactHandler(),
            CreateAgentCalendarEventHandler(),
            UpdateAgentCalendarEventHandler(),
            ModifyGoalPlanHandler(),
            MarkGoalProgressHandler(),
            SnoozeOpenLoopHandler(),
            DismissSignalHandler()
        ]
    }

    private var store: MemoryStore { MemoryStore(context: context, clock: clock) }
    private var handlerContext: HandlerContext {
        HandlerContext(context: context, clock: clock, calendar: calendar)
    }

    // MARK: - Queue

    /// The Phase 5 seam: enqueue a freshly-built Proposal as `pending`. This is the *only* way
    /// a propose-tool (or a Phase 3A/3B builder) puts work into the Inbox — it can never
    /// execute. Forces status to `pending` defensively, then inserts append-only.
    @discardableResult
    public func enqueue(_ proposal: Proposal) throws -> Proposal {
        proposal.status = .pending
        try store.insert(proposal)
        return proposal
    }

    /// Enqueue a batch (e.g. a Weekly Review's next-week blocks). Skips ones whose stable
    /// `factKey` already has an active proposal, so re-running the builder does not duplicate.
    @discardableResult
    public func enqueueBatch(_ proposals: [Proposal]) throws -> [Proposal] {
        var inserted: [Proposal] = []
        for p in proposals {
            let existing = try store.activeRevisions(Proposal.self, factKey: p.factKey)
            guard existing.isEmpty else { continue }
            inserted.append(try enqueue(p))
        }
        return inserted
    }

    /// Currently-pending proposals (the Inbox contents), newest first.
    public func pendingProposals(asOf: Date? = nil) throws -> [Proposal] {
        let now = asOf ?? clock.now
        return try store.all(Proposal.self)
            .filter { $0.status == .pending && !$0.isExpired(asOf: now) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Transitions

    /// Approve a pending proposal: run exactly ONE handler (the one matching its type), then
    /// mark it `approved`. The single dispatch is the "no inferred follow-up action" guarantee.
    @discardableResult
    public func approve(_ proposal: Proposal, asOf: Date? = nil) async throws -> ExecutionReceipt {
        let now = asOf ?? clock.now
        guard proposal.status == .pending else { throw ProposalError.notPending(proposal.status) }

        // Expiration drops the proposal — it is never executed, even if not yet swept.
        if proposal.isExpired(asOf: now) {
            proposal.status = .expired
            proposal.updatedAt = now
            try context.save()
            throw ProposalError.expired
        }

        guard let handler = handlers[proposal.proposalType] else {
            throw ProposalError.noHandler(proposal.proposalType)
        }

        // The ONE place an ApprovalGrant is minted. Dispatch to exactly one handler.
        let grant = ApprovalGrant(proposalAppID: proposal.appID)
        let receipt = try await handler.execute(proposal, grant: grant, context: handlerContext)

        // Only on success does the proposal become terminal-approved (failed writes stay pending).
        proposal.status = .approved
        proposal.updatedAt = now
        try context.save()
        return receipt
    }

    /// Dismiss a pending proposal — terminal, never executes.
    public func dismiss(_ proposal: Proposal, asOf: Date? = nil) throws {
        try transition(proposal, to: .dismissed, asOf: asOf)
    }

    /// Snooze a pending proposal until `until`. It leaves the Inbox (never executes) and
    /// resurfaces to `pending` once `resurfaceDueSnoozed(asOf:)` runs at/after `until`. The
    /// resurface time is stored in `expiresAt`, interpreted per status: on a `pending`
    /// proposal `expiresAt` is a drop-dead expiry; on a `snoozed` one it is the resurface time.
    public func snooze(_ proposal: Proposal, until: Date, asOf: Date? = nil) throws {
        let now = asOf ?? clock.now
        guard proposal.status == .pending else { throw ProposalError.notPending(proposal.status) }
        proposal.status = .snoozed
        proposal.expiresAt = until
        proposal.updatedAt = now
        try context.save()
    }

    /// Mark a pending proposal **wrong**: dismiss it AND persist a durable `RejectionSignal`
    /// (Phase 4B downranks similar future extraction from the same `sourcePattern`). When no
    /// `sourcePattern` is supplied, the proposal's `factKey` is used (4B supplies a stable
    /// source descriptor for Gmail-derived proposals). Returns the recorded signal.
    @discardableResult
    public func markAsWrong(_ proposal: Proposal,
                            sourcePattern: String? = nil,
                            asOf: Date? = nil) throws -> RejectionSignal {
        let now = asOf ?? clock.now
        guard proposal.status == .pending else { throw ProposalError.notPending(proposal.status) }

        let signal = RejectionSignal(
            proposalType: proposal.proposalType,
            source: proposal.source,
            sourcePattern: sourcePattern ?? proposal.factKey,
            proposalAppID: proposal.appID,
            rejectedAt: now)
        try RejectionSignalStore(store: store).record(signal)

        proposal.status = .dismissed
        proposal.correctionReason = "marked wrong by user"
        proposal.updatedAt = now
        try context.save()
        return signal
    }

    /// Explicitly expire a pending proposal (drop it; never executes).
    public func expire(_ proposal: Proposal, asOf: Date? = nil) throws {
        try transition(proposal, to: .expired, asOf: asOf)
    }

    // MARK: - Sweeps

    /// Sweep: expire every pending proposal past its `expiresAt` as of `asOf`. Returns the count.
    @discardableResult
    public func expirePendingPastDue(asOf: Date? = nil) throws -> Int {
        let now = asOf ?? clock.now
        let due = try store.all(Proposal.self).filter {
            $0.status == .pending && $0.isExpired(asOf: now)
        }
        for p in due { p.status = .expired; p.updatedAt = now }
        if !due.isEmpty { try context.save() }
        return due.count
    }

    /// Sweep: resurface every snoozed proposal whose resurface time (`expiresAt`) has arrived.
    /// Clears `expiresAt` so a resurfaced proposal is not instantly re-expired. Returns the count.
    @discardableResult
    public func resurfaceDueSnoozed(asOf: Date? = nil) throws -> Int {
        let now = asOf ?? clock.now
        let due = try store.all(Proposal.self).filter {
            $0.status == .snoozed && ($0.expiresAt.map { $0 <= now } ?? false)
        }
        for p in due { p.status = .pending; p.expiresAt = nil; p.updatedAt = now }
        if !due.isEmpty { try context.save() }
        return due.count
    }

    // MARK: - Batch

    /// Batch-approve: approves each pending proposal, running exactly its own handler. Returns
    /// receipts for the ones that succeeded; a failing one throws and leaves the rest as-is (the
    /// caller can retry). Used by the Sunday Weekly-Review approval session.
    @discardableResult
    public func approveBatch(_ proposals: [Proposal], asOf: Date? = nil) async throws -> [ExecutionReceipt] {
        var receipts: [ExecutionReceipt] = []
        for p in proposals where p.status == .pending {
            receipts.append(try await approve(p, asOf: asOf))
        }
        return receipts
    }

    /// Batch-dismiss: dismisses each pending proposal. Individual dismissal excludes only those.
    public func dismissBatch(_ proposals: [Proposal], asOf: Date? = nil) throws {
        for p in proposals where p.status == .pending {
            try dismiss(p, asOf: asOf)
        }
    }

    // MARK: - Private

    private func transition(_ proposal: Proposal, to status: ProposalStatus, asOf: Date?) throws {
        let now = asOf ?? clock.now
        guard proposal.status == .pending else { throw ProposalError.notPending(proposal.status) }
        proposal.status = status
        proposal.updatedAt = now
        try context.save()
    }
}
