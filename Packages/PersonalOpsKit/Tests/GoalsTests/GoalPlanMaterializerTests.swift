import XCTest
import SwiftData
import Core
import Data
import Fixtures
@testable import Goals

/// Persistence: a generated plan becomes an active `Goal` (revision 1) with `GoalTask`
/// children carrying the plan's scheduling metadata, written through `MemoryStore` — and
/// nothing else.
final class GoalPlanMaterializerTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 0)
    private let week: TimeInterval = 7 * 86_400

    private func context() throws -> ModelContext {
        ModelContext(try DataStore.makeContainer(inMemory: true))
    }

    func test_persistsGoalAndTasks_asActiveRevisionOne() throws {
        let clock = FakeClock(now: epoch)
        let ctx = try context()
        let store = MemoryStore(context: ctx, clock: clock)

        let plan = GoalPlanner().generatePlan(
            playbook: PlaybookLibrary.triathlonTraining,
            answers: IntakeAnswers(),
            goalTitle: "Ironman 70.3 in October",
            now: clock.now,
            targetDate: clock.now.addingTimeInterval(4 * week))

        let goal = try GoalPlanMaterializer(store: store)
            .persist(plan, now: clock.now)

        XCTAssertEqual(goal.revision, 1)
        XCTAssertEqual(goal.status, .active)
        XCTAssertEqual(goal.playbookKey, "training")
        XCTAssertEqual(goal.factKey, "goal:ironman_70_3_in_october")
        XCTAssertEqual(goal.tasks?.count, plan.tasks.count)

        // The store resolves the goal to a single active revision (no conflict, no dupes).
        let resolution = try store.resolve(Goal.self, factKey: goal.factKey)
        XCTAssertNotNil(resolution.value)
    }

    func test_persistedTasks_carryPlanSchedulingMetadata() throws {
        let clock = FakeClock(now: epoch)
        let ctx = try context()
        let store = MemoryStore(context: ctx, clock: clock)

        let plan = GoalPlanner().generatePlan(
            playbook: PlaybookLibrary.triathlonTraining,
            answers: IntakeAnswers(),
            goalTitle: "Ironman",
            now: clock.now,
            targetDate: clock.now.addingTimeInterval(2 * week))
        let goal = try GoalPlanMaterializer(store: store).persist(plan, now: clock.now)

        // A fixed/blocking swim survived the round-trip with its metadata intact.
        let tasks = goal.tasks ?? []
        XCTAssertTrue(tasks.contains { $0.flexibility == .fixed && $0.conflictPolicy == .block })
        XCTAssertTrue(tasks.allSatisfy { $0.earliestAcceptable != nil && $0.latestAcceptable != nil })
    }

    func test_persistedPlan_isSlipDetectable() throws {
        // End-to-end: generate → persist → later, with no progress, slip detection fires.
        let clock = FakeClock(now: epoch)
        let ctx = try context()
        let store = MemoryStore(context: ctx, clock: clock)

        let plan = GoalPlanner().generatePlan(
            playbook: PlaybookLibrary.triathlonTraining,
            answers: IntakeAnswers(),
            goalTitle: "Ironman",
            now: clock.now,
            targetDate: clock.now.addingTimeInterval(2 * week))
        let goal = try GoalPlanMaterializer(store: store).persist(plan, now: clock.now)

        // Far in the future, nothing was ever logged as done → week-0 tasks have slipped.
        let asOf = clock.now.addingTimeInterval(3 * week)
        let slipped = SlipDetector().slippedTasks(
            tasks: goal.tasks ?? [],
            progress: [],
            rule: PlaybookLibrary.triathlonTraining.slipRule,
            asOf: asOf)
        XCTAssertFalse(slipped.isEmpty)
    }
}
