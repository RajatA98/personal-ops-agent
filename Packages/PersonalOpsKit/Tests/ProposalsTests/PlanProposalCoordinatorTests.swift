import XCTest
import SwiftData
import Core
import Data
import Goals
import DailyLoop
import Integrations
import Fixtures
@testable import Proposals

/// # PlanProposalCoordinatorTests — the wired-source integration tests (REVIEW_REPORT Major-1)
///
/// Proves the two previously-unreachable deterministic proposal sources now land **pending**
/// Proposals through the engine when their UI action fires:
///   • the goal-plan "Propose schedule" action (schedule blocks + cross-goal conflicts), and
///   • the Weekly Review "Plan next week" action.
/// Each test drives the exact seam the view's button calls (`PlanProposalCoordinator`) against a
/// real in-memory engine, then asserts pending proposals exist and **nothing executed** (no
/// calendar write) — the "propose, don't act" guarantee end-to-end.
@MainActor
final class PlanProposalCoordinatorTests: XCTestCase {

    // MARK: Fixtures

    private func persistedGoal(title: String,
                               tasks: [GoalTask],
                               into store: MemoryStore) throws -> Goal {
        let goal = Goal(title: title)
        goal.factKey = "goal:\(title.lowercased())"
        goal.tasks = tasks
        try store.insert(goal)
        return goal
    }

    private func task(_ title: String,
                      start: Date,
                      duration: TimeInterval = PX.hour,
                      flexibility: TaskFlexibility = .movable,
                      policy: ConflictPolicy = .warn) -> GoalTask {
        GoalTask(title: title, flexibility: flexibility, priority: 1,
                 earliestAcceptable: start,
                 latestAcceptable: start.addingTimeInterval(duration),
                 expectedDuration: duration, conflictPolicy: policy)
    }

    // MARK: Propose schedule

    func test_proposeSchedule_landsPendingCreateEventProposals_andWritesNothing() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)
        let fakeCalendar = FakeGoogleCalendarAPI()
        let engine = ProposalEngine(context: ctx, clock: clock, calendar: fakeCalendar)

        let goal = try persistedGoal(
            title: "Ironman",
            tasks: [task("Swim", start: PX.now + PX.day),
                    task("Long ride", start: PX.now + 2 * PX.day)],
            into: store)

        let coordinator = PlanProposalCoordinator(context: ctx, clock: clock, engine: engine)
        let summary = try coordinator.proposeSchedule(for: goal, amongActiveGoals: [goal])

        XCTAssertEqual(summary.scheduled, 2, "one create-event proposal per scheduled task")
        XCTAssertEqual(summary.conflicts, 0, "single goal → no cross-goal conflict")

        let pending = try engine.pendingProposals()
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.status == .pending })
        XCTAssertTrue(pending.allSatisfy { $0.proposalType == .createAgentCalendarEvent })
        // Proving containment: proposing executed NOTHING.
        XCTAssertTrue(fakeCalendar.createdEvents.isEmpty, "no calendar write on propose")
    }

    func test_proposeSchedule_surfacesCrossGoalConflictAsPendingProposal() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)
        let fakeCalendar = FakeGoogleCalendarAPI()
        let engine = ProposalEngine(context: ctx, clock: clock, calendar: fakeCalendar)

        // Two goals whose blocks overlap: a fixed/blocking swim vs a movable interview-prep block.
        let training = try persistedGoal(
            title: "Training",
            tasks: [task("Dawn swim", start: PX.now, flexibility: .fixed, policy: .block)],
            into: store)
        let jobs = try persistedGoal(
            title: "Job search",
            tasks: [task("Interview prep", start: PX.now + 1800, flexibility: .movable, policy: .warn)],
            into: store)

        let coordinator = PlanProposalCoordinator(context: ctx, clock: clock, engine: engine)
        let summary = try coordinator.proposeSchedule(for: training, amongActiveGoals: [training, jobs])

        XCTAssertEqual(summary.scheduled, 1, "the target goal's one scheduled task")
        XCTAssertEqual(summary.conflicts, 1, "the cross-goal overlap surfaces as a proposal")

        let pending = try engine.pendingProposals()
        XCTAssertTrue(pending.contains { $0.proposalType == .modifyGoalPlan && $0.status == .pending },
                      "a pending modify_goal_plan conflict proposal is in the Inbox")
        XCTAssertTrue(fakeCalendar.createdEvents.isEmpty, "no calendar write on propose")
    }

    func test_proposeSchedule_reRun_dedupesByFactKey() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)
        let engine = ProposalEngine(context: ctx, clock: clock, calendar: FakeGoogleCalendarAPI())
        let goal = try persistedGoal(
            title: "Ironman",
            tasks: [task("Swim", start: PX.now + PX.day)],
            into: store)

        let coordinator = PlanProposalCoordinator(context: ctx, clock: clock, engine: engine)
        let first = try coordinator.proposeSchedule(for: goal, amongActiveGoals: [goal])
        XCTAssertEqual(first.scheduled, 1)
        // Tapping again re-derives the same stable per-task factKey → deduped, nothing new.
        let second = try coordinator.proposeSchedule(for: goal, amongActiveGoals: [goal])
        XCTAssertEqual(second.scheduled, 0)
        XCTAssertEqual(try engine.pendingProposals().count, 1)
    }

    // MARK: Plan next week

    private func briefingTask(_ title: String, start: Date) -> BriefingTask {
        BriefingTask(taskID: UUID(), goalID: UUID(), goalTitle: "g", title: title,
                     flexibility: .movable, priority: 1,
                     earliestAcceptable: start, latestAcceptable: start + PX.hour, isComplete: false)
    }

    private func fixtureReview() -> WeeklyReview {
        let training = WeeklyGoalRollup(
            goalID: UUID(), goalTitle: "Ironman", completed: [], slipped: [],
            nextWeek: [briefingTask("Swim", start: PX.now + PX.day),
                       briefingTask("Long ride", start: PX.now + 2 * PX.day)])
        return WeeklyReview(weekStart: PX.now - 7 * PX.day, weekEnd: PX.now,
                            goals: [training], degradedSources: [])
    }

    func test_planNextWeek_landsPendingProposals_andWritesNothing() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let fakeCalendar = FakeGoogleCalendarAPI()
        let engine = ProposalEngine(context: ctx, clock: clock, calendar: fakeCalendar)

        let coordinator = PlanProposalCoordinator(context: ctx, clock: clock, engine: engine)
        let count = try coordinator.planNextWeek(from: fixtureReview())

        XCTAssertEqual(count, 2, "one pending proposal per next-week task")
        let pending = try engine.pendingProposals()
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.status == .pending && $0.proposalType == .createAgentCalendarEvent })
        XCTAssertTrue(fakeCalendar.createdEvents.isEmpty, "no calendar write on plan-next-week")
    }
}
