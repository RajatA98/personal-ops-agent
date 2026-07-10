import Foundation
import Core
import Data
import Goals

/// # ScheduleProposalBuilder — Phase 3A preview → a batch of create-event Proposals
///
/// Turns a goal's persisted `GoalTask`s (the same tasks a `SchedulePreview` renders) into a
/// batch of `create_agent_calendar_event` Proposals. The idempotency key is seeded from each
/// task's **stable `GoalTask.appID`** (Phase 3A's prescribed seed), so:
///   • approving one twice creates exactly one event (Phase 2's idempotent write path), and
///   • re-deriving the batch reuses the same key/`factKey`, so nothing double-books.
///
/// This builder writes nothing itself — it only *constructs* pending Proposals. Execution is
/// still gated behind an approved proposal in the engine (Safety Rule #1/#2).
public struct ScheduleProposalBuilder {
    public init() {}

    /// Build create-event proposals for every task that has a scheduled start
    /// (`earliestAcceptable`). `expiresAfter` sets each proposal's drop-dead expiry (default 14
    /// days — a stale schedule block should not linger).
    public func proposals(
        forTasks tasks: [GoalTask],
        goalTitle: String,
        now: Date,
        expiresAfter: TimeInterval? = 14 * 86_400
    ) -> [Proposal] {
        tasks.compactMap { task in
            guard let start = task.earliestAcceptable else { return nil }
            let end = start.addingTimeInterval(task.expectedDuration)
            let key = Self.idempotencyKey(forTaskAppID: task.appID)
            let payload = CreateAgentCalendarEventPayload(
                title: task.title, start: start, end: end, idempotencyKey: key)

            let proposal = Proposal(
                source: .inference,
                confidence: 0.9,
                createdAt: now,
                updatedAt: now,
                expiresAt: expiresAfter.map { now.addingTimeInterval($0) },
                type: .createAgentCalendarEvent,
                status: .pending,
                rationale: "Scheduled from your \(goalTitle) plan.",
                payload: (try? ProposalPayloadCoder.encode(payload)) ?? "",
                affectedAppID: task.appID)
            proposal.factKey = "proposal:create_event:\(key)"
            return proposal
        }
    }

    /// The stable idempotency key for a task — shared with `WeeklyReviewProposalBuilder` so both
    /// paths produce the same key for the same task (no duplicate agent events).
    public static func idempotencyKey(forTaskAppID appID: UUID) -> String {
        "goaltask:\(appID.uuidString)"
    }
}
