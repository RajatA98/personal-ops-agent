import XCTest
import SwiftData
import Core
import Data
import Integrations
import Fixtures
@testable import Proposals

/// Each real handler performs exactly its own action against the store — happy-path proof.
@MainActor
final class HandlerExecutionTests: XCTestCase {

    private func engine(_ ctx: ModelContext, _ clock: FakeClock,
                        calendar: (any GoogleCalendarAPI)? = nil) -> ProposalEngine {
        ProposalEngine(context: ctx, clock: clock, calendar: calendar) // default handlers
    }

    func test_rememberFact_persistsPreference() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let eng = engine(ctx, clock)

        let payload = RememberFactPayload(factKey: "preference:coffee", key: "coffee", value: "oat latte")
        let p = PX.pending(.rememberFact, payload: payload)
        try eng.enqueue(p)
        _ = try await eng.approve(p)

        let store = MemoryStore(context: ctx, clock: clock)
        guard case let .resolved(pref) = try store.resolve(Preference.self, factKey: "preference:coffee") else {
            return XCTFail("expected a resolved preference")
        }
        XCTAssertEqual(pref.value, "oat latte")
        XCTAssertEqual(pref.source, .user)
    }

    func test_markGoalProgress_appendsGoalProgress() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)
        let goal = Goal(source: .user, createdAt: PX.now, updatedAt: PX.now, title: "Ironman", playbookKey: "training")
        goal.factKey = "goal:ironman"
        try store.insert(goal)

        let eng = engine(ctx, clock)
        let payload = MarkGoalProgressPayload(goalAppID: goal.appID,
                                              progressFactKey: "goal_progress:\(UUID().uuidString)",
                                              metricKey: "weekly_long_run_km", value: 18, note: "felt good")
        let p = PX.pending(.markGoalProgress, payload: payload)
        try eng.enqueue(p)
        _ = try await eng.approve(p)

        let all = try store.all(GoalProgress.self)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.value, 18)
        XCTAssertEqual(all.first?.goal?.appID, goal.appID)
    }

    func test_modifyGoalPlan_correctsGoalTask() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)
        let task = GoalTask(createdAt: PX.now, updatedAt: PX.now, title: "Easy run", isComplete: false)
        let goal = Goal(source: .user, createdAt: PX.now, updatedAt: PX.now, title: "Ironman", playbookKey: "training")
        goal.factKey = "goal:ironman"
        goal.tasks = [task]
        try store.insert(goal)

        let eng = engine(ctx, clock)
        let payload = ModifyGoalPlanPayload(goalTaskAppID: task.appID, newTitle: "Tempo run", markComplete: true)
        let p = PX.pending(.modifyGoalPlan, payload: payload)
        try eng.enqueue(p)
        _ = try await eng.approve(p)

        XCTAssertEqual(task.title, "Tempo run")
        XCTAssertTrue(task.isComplete)
    }

    func test_modifyGoalPlan_missingTask_throws_leavesPending() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let eng = engine(ctx, clock)
        let payload = ModifyGoalPlanPayload(goalTaskAppID: UUID(), newTitle: "x")
        let p = PX.pending(.modifyGoalPlan, payload: payload)
        try eng.enqueue(p)

        await XCTAssertThrowsErrorAsync(try await eng.approve(p)) { error in
            XCTAssertEqual(error as? ProposalError, .targetNotFound)
        }
        XCTAssertEqual(p.status, .pending, "a failed handler leaves the proposal pending to retry")
    }

    func test_snoozeOpenLoop_setsSnoozedUntil() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)
        let loop = OpenLoop(source: .user, createdAt: PX.now, updatedAt: PX.now, title: "Recruiter reply")
        loop.factKey = "open_loop:recruiter"
        try store.insert(loop)

        let eng = engine(ctx, clock)
        let until = PX.now + 3 * PX.day
        let payload = SnoozeOpenLoopPayload(openLoopAppID: loop.appID, snoozeUntil: until)
        let p = PX.pending(.snoozeOpenLoop, payload: payload)
        try eng.enqueue(p)
        _ = try await eng.approve(p)

        XCTAssertEqual(loop.snoozedUntil, until)
    }

    func test_dismissSignal_resolvesOpenLoop() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)
        let loop = OpenLoop(source: .gmail, createdAt: PX.now, updatedAt: PX.now, title: "Maybe-a-task email")
        loop.factKey = "open_loop:maybe"
        try store.insert(loop)

        let eng = engine(ctx, clock)
        let payload = DismissSignalPayload(openLoopAppID: loop.appID, reason: "not a task")
        let p = PX.pending(.dismissSignal, payload: payload)
        try eng.enqueue(p)
        _ = try await eng.approve(p)

        XCTAssertTrue(loop.isResolved)
    }

    /// Confirmation copy is distinct and non-empty for every type.
    func test_confirmationCopy_distinctPerType() {
        let verbs = ProposalType.allCases.map { ProposalConfirmationCopy.copy(for: $0).actionVerb }
        XCTAssertEqual(Set(verbs).count, verbs.count, "each type has a distinct action verb")
        XCTAssertTrue(verbs.allSatisfy { !$0.isEmpty })
    }
}
