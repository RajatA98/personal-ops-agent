import XCTest
import Core
import Fixtures
@testable import Goals

/// The deterministic planning engine: horizon math, milestone placement, task expansion,
/// and the flexibility-driven slip window that later feeds `SlipDetector`.
final class GoalPlannerTests: XCTestCase {

    private let planner = GoalPlanner()
    private let epoch = Date(timeIntervalSince1970: 0)
    private let week: TimeInterval = 7 * 86_400

    func test_taskCount_matchesWeeklyFrequencyTimesWeeks() {
        let weeks = 6
        let plan = planner.generatePlan(
            playbook: PlaybookLibrary.triathlonTraining,
            answers: IntakeAnswers(),
            goalTitle: "Ironman 70.3",
            now: epoch,
            targetDate: epoch.addingTimeInterval(Double(weeks) * week))

        let expectedPerWeek = PlaybookLibrary.triathlonTraining.taskRules
            .reduce(0) { $0 + $1.weeklyFrequency }
        XCTAssertEqual(plan.tasks.count, expectedPerWeek * weeks)
    }

    func test_milestones_placedAlongTimeline() {
        let weeks = 10
        let target = epoch.addingTimeInterval(Double(weeks) * week)
        let plan = planner.generatePlan(
            playbook: PlaybookLibrary.triathlonTraining,
            answers: IntakeAnswers(),
            goalTitle: "Ironman 70.3",
            now: epoch,
            targetDate: target)

        // First milestone (fraction 0) at the start; last (fraction 1) at the target.
        XCTAssertEqual(plan.milestones.first?.date, epoch)
        XCTAssertEqual(plan.milestones.last?.date.timeIntervalSince1970 ?? 0,
                       target.timeIntervalSince1970, accuracy: 1)
        // Monotonic non-decreasing along the timeline.
        let dates = plan.milestones.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
    }

    func test_shortHorizon_stillProducesAtLeastOneWeek() {
        // Target in the past / same day → clamp to a single week, never an empty plan.
        let plan = planner.generatePlan(
            playbook: PlaybookLibrary.jobSearch,
            answers: IntakeAnswers(),
            goalTitle: "Land PM role",
            now: epoch,
            targetDate: epoch) // same instant
        XCTAssertFalse(plan.tasks.isEmpty)
        XCTAssertTrue(plan.tasks.allSatisfy { $0.weekIndex == 0 })
    }

    func test_fixedTasks_haveTighterSlipWindowThanOptional() {
        let plan = planner.generatePlan(
            playbook: PlaybookLibrary.triathlonTraining,
            answers: IntakeAnswers(),
            goalTitle: "Ironman 70.3",
            now: epoch,
            targetDate: epoch.addingTimeInterval(4 * week))

        // For a fixed task, latestAcceptable == start + duration (no slack).
        let fixed = try! XCTUnwrap(plan.tasks.first { $0.flexibility == .fixed })
        XCTAssertEqual(fixed.latestAcceptable,
                       fixed.earliestAcceptable.addingTimeInterval(fixed.expectedDuration))

        // For an optional task, latestAcceptable is meaningfully later (has slack).
        let optional = try! XCTUnwrap(plan.tasks.first { $0.flexibility == .optional })
        XCTAssertGreaterThan(
            optional.latestAcceptable.timeIntervalSince(optional.earliestAcceptable),
            optional.expectedDuration)
    }

    func test_weekendAnchoredTask_landsOnSaturday() {
        let plan = planner.generatePlan(
            playbook: PlaybookLibrary.triathlonTraining,
            answers: IntakeAnswers(),
            goalTitle: "Ironman 70.3",
            now: epoch,
            targetDate: epoch.addingTimeInterval(2 * week))

        // The long ride uses the Saturday (weekday 7) template. Week 0 Saturday at hour 8:
        // 1970-01-01 (epoch) is a Thursday; weekday index 6 (Sat) → +6 days, +8h.
        let longRideWeek0 = try! XCTUnwrap(
            plan.tasks.first { $0.ruleKey == "long_ride" && $0.weekIndex == 0 })
        XCTAssertEqual(longRideWeek0.earliestAcceptable,
                       epoch.addingTimeInterval(6 * 86_400 + 8 * 3_600))
    }
}
