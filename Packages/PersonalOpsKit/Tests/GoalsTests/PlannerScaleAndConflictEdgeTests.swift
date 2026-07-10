import XCTest
import Core
import Data
@testable import Goals

/// Test-QA edge-case probe (Phase 8). Two high-risk edges the existing suites don't cover:
/// (1) a very long planning horizon (a year) — the planner must stay bounded, well-formed, and
/// deterministic rather than blowing up or emitting malformed windows; (2) N-way (>2) cross-goal
/// conflicts — the existing `ConflictDetectorTests` only cover single pairs, so this confirms
/// three mutually-overlapping goals surface all C(3,2)=3 pairwise conflicts, deterministically.
final class PlannerScaleAndConflictEdgeTests: XCTestCase {

    private let planner = GoalPlanner()
    private let now = Date(timeIntervalSince1970: 100 * 86_400)

    // MARK: - Large / long-horizon plan

    func test_yearLongHorizon_staysBoundedWellFormedAndDeterministic() {
        let playbook = PlaybookLibrary.playbook(forKey: "training")!
        let target = now.addingTimeInterval(365 * 86_400)
        let plan = planner.generatePlan(
            playbook: playbook, answers: IntakeAnswers(),
            goalTitle: "Ironman 70.3", now: now, targetDate: target)

        // Non-empty and genuinely large (a year of weekly training blocks), proving it scales.
        XCTAssertGreaterThan(plan.tasks.count, 100)

        // Task count is exactly weeks × per-week — bounded, no runaway expansion.
        let weeks = Set(plan.tasks.map(\.weekIndex)).count
        let perWeek = plan.tasks.filter { $0.weekIndex == 0 }.count
        XCTAssertEqual(plan.tasks.count, weeks * perWeek)
        XCTAssertEqual(weeks, 53, "365 days (÷7 = 52.14) rounds up to 53 planning weeks")

        // Every emitted task is well-formed: latest ≥ earliest, week index in range,
        // positive duration.
        for t in plan.tasks {
            XCTAssertGreaterThanOrEqual(t.latestAcceptable, t.earliestAcceptable)
            XCTAssertGreaterThan(t.expectedDuration, 0)
            XCTAssertTrue((0..<weeks).contains(t.weekIndex))
        }

        // Deterministic: replanning the same inputs yields byte-identical tasks.
        let again = planner.generatePlan(
            playbook: playbook, answers: IntakeAnswers(),
            goalTitle: "Ironman 70.3", now: now, targetDate: target)
        XCTAssertEqual(plan.tasks, again.tasks)
    }

    // MARK: - N-way cross-goal conflicts

    func test_threeGoalsMutuallyOverlapping_surfaceAllThreePairwiseConflicts() {
        let detector = ConflictDetector()
        let t0 = now
        func block(goal: UUID, title: String) -> ScheduledBlock {
            // All three share the same hour, so every pair overlaps.
            ScheduledBlock(taskAppID: UUID(), goalID: goal, goalTitle: title, title: title,
                           start: t0, end: t0.addingTimeInterval(3600),
                           flexibility: .fixed, priority: 0, conflictPolicy: .block)
        }
        let a = block(goal: UUID(), title: "A")
        let b = block(goal: UUID(), title: "B")
        let c = block(goal: UUID(), title: "C")

        let conflicts = detector.detect(blocks: [a, b, c])
        // Three distinct goals mutually overlapping → C(3,2) = 3 pairwise conflicts.
        XCTAssertEqual(conflicts.count, 3)
        XCTAssertEqual(Set(conflicts.map(\.pairKey)).count, 3, "each pair reported once, no dupes")
        XCTAssertTrue(conflicts.allSatisfy { $0.severity == .hard })

        // Order-independent: shuffling the input yields the same set of pair keys.
        let shuffled = detector.detect(blocks: [c, a, b])
        XCTAssertEqual(conflicts.map(\.pairKey), shuffled.map(\.pairKey))
    }
}
