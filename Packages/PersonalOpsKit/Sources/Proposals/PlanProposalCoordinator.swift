import Foundation
import SwiftData
import Core
import Data
import Goals
import DailyLoop
import Integrations

/// # PlanProposalCoordinator — the UI seam that routes deterministic plans into the Ops Inbox
///
/// Phase 4A/4C built `ScheduleProposalBuilder`, `ConflictProposalBuilder`/`ConflictDetector`, and
/// `WeeklyReviewProposalBuilder`, but no shipped view called them (REVIEW_REPORT Major-1). This
/// coordinator is the single, testable entry point those views now invoke: it turns a goal's
/// persisted plan or a Weekly Review into a batch of **pending** Proposals and enqueues them
/// through `ProposalEngine.enqueueBatch`.
///
/// It adds **no execution path**. Every proposal it produces is `.pending`; the only way any of
/// them ever runs is the user approving it in the Ops Inbox (Safety Rule #1 — the write seam stays
/// singular). `enqueueBatch`'s active-`factKey` dedupe means re-running an action never stacks
/// duplicates (the builders seed stable per-task / per-conflict keys).
///
/// `@MainActor` because it drives a `ModelContext`-bound `ProposalEngine`.
@MainActor
public final class PlanProposalCoordinator {
    private let engine: ProposalEngine
    private let clock: any Clock

    /// The engine is injectable so tests can pass a spy-handler engine; production callers pass a
    /// `context` (+ the optional agent `calendar` the engine only ever uses at *approve* time).
    public init(context: ModelContext,
                clock: any Clock = SystemClock(),
                calendar: (any GoogleCalendarAPI)? = nil,
                engine: ProposalEngine? = nil) {
        self.clock = clock
        self.engine = engine ?? ProposalEngine(context: context, clock: clock, calendar: calendar)
    }

    /// Result of a "Propose schedule" action: how many new pending proposals actually landed
    /// (after factKey dedupe), split into schedule blocks and surfaced cross-goal conflicts.
    public struct ScheduleProposalSummary: Equatable, Sendable {
        public let scheduled: Int
        public let conflicts: Int
        public var total: Int { scheduled + conflicts }
        public init(scheduled: Int, conflicts: Int) {
            self.scheduled = scheduled
            self.conflicts = conflicts
        }
    }

    /// "Propose schedule" (goal-plan preview → Ops Inbox).
    ///
    /// Builds create-event proposals for `goal`'s scheduled tasks, AND runs cross-goal conflict
    /// detection across *all* the active goals passed in (so a collision surfaces as its own
    /// `modify_goal_plan` proposal alongside the schedule, rather than silently double-booking —
    /// PRD Conflict Detection / Safety Rule #6). Both batches go in as `.pending`.
    @discardableResult
    public func proposeSchedule(for goal: Goal,
                                amongActiveGoals goals: [Goal],
                                now: Date? = nil) throws -> ScheduleProposalSummary {
        let t = now ?? clock.now

        let scheduleProposals = ScheduleProposalBuilder().proposals(
            forTasks: goal.tasks ?? [], goalTitle: goal.title, now: t)
        let insertedSchedule = try engine.enqueueBatch(scheduleProposals)

        // Cross-goal conflicts across every active goal's persisted, scheduled tasks.
        let groups = goals.map { g in
            (goalID: g.appID,
             goalTitle: g.title,
             blocks: ScheduledBlock.from(tasks: g.tasks ?? [], goalID: g.appID, goalTitle: g.title))
        }
        let conflictProposals = ConflictProposalBuilder().detectAndBuild(acrossGoals: groups, now: t)
        let insertedConflicts = try engine.enqueueBatch(conflictProposals)

        return ScheduleProposalSummary(scheduled: insertedSchedule.count,
                                       conflicts: insertedConflicts.count)
    }

    /// "Plan next week" (Weekly Review → Ops Inbox). Turns the review's per-goal `nextWeek` bucket
    /// into a batch of pending create-event proposals. Returns the count actually enqueued.
    @discardableResult
    public func planNextWeek(from review: WeeklyReview, now: Date? = nil) throws -> Int {
        let t = now ?? clock.now
        let proposals = WeeklyReviewProposalBuilder().nextWeekProposals(from: review, now: t)
        return try engine.enqueueBatch(proposals).count
    }
}
