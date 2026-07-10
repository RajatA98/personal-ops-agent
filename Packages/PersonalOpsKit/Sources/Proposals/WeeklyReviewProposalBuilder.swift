import Foundation
import Core
import Data
import DailyLoop

/// # WeeklyReviewProposalBuilder — Sunday's next-week batch
///
/// Turns a `WeeklyReview`'s `goals[].nextWeek` (Phase 3B's deterministic rollup) into a batch
/// of `create_agent_calendar_event` Proposals, so one approval session plans the week. Each
/// next-week `BriefingTask` carries `taskID == GoalTask.appID`, so the idempotency key is
/// seeded identically to `ScheduleProposalBuilder` — the two paths never double-book the same
/// task.
///
/// `BriefingTask` carries no duration (it is a flat briefing snapshot), so blocks default to
/// `defaultDuration`; a task with no `earliestAcceptable` (no scheduled start) is skipped.
public struct WeeklyReviewProposalBuilder {
    public init() {}

    public func nextWeekProposals(
        from review: WeeklyReview,
        now: Date,
        defaultDuration: TimeInterval = 3_600,
        expiresAfter: TimeInterval? = 9 * 86_400
    ) -> [Proposal] {
        review.goals.flatMap { rollup in
            rollup.nextWeek.compactMap { task -> Proposal? in
                guard let start = task.earliestAcceptable else { return nil }
                let end = start.addingTimeInterval(defaultDuration)
                let key = ScheduleProposalBuilder.idempotencyKey(forTaskAppID: task.taskID)
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
                    rationale: "Next week for \(rollup.goalTitle).",
                    payload: (try? ProposalPayloadCoder.encode(payload)) ?? "",
                    affectedAppID: task.taskID)
                proposal.factKey = "proposal:create_event:\(key)"
                return proposal
            }
        }
    }
}
