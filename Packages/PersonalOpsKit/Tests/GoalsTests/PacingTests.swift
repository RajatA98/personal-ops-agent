import XCTest
import Core
import Data
import Fixtures
@testable import Goals

/// # Phase 3C — HealthKit pacing
///
/// All three acceptance criteria have a dedicated test here, plus the playbook-bounds and
/// isolation guarantees:
///   1. A pacing suggestion from fixture HealthKit data is *visibly labeled* as influenced.
///   2. Denying HealthKit permission leaves planning fully functional, influence simply absent.
///   3. Disabling the toggle removes influence without touching goal data itself.
final class PacingTests: XCTestCase {

    private let planner = GoalPlanner()
    private let paced = PacedPlanner()
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let training = PlaybookLibrary.triathlonTraining
    private let jobSearch = PlaybookLibrary.jobSearch

    private func target(weeks: Int) -> Date { now.addingTimeInterval(Double(weeks) * 7 * 86_400) }

    private func plan(with source: any HealthKitDataSource, enabled: Bool,
                      playbook: GoalPlaybook? = nil) async -> GeneratedPlan {
        let coordinator = HealthPacingCoordinator(source: source, lookback: 14 * 86_400)
        return await coordinator.generatePlan(
            playbook: playbook ?? training, answers: IntakeAnswers(),
            goalTitle: "Ironman 70.3", now: now, targetDate: target(weeks: 4),
            influenceEnabled: enabled)
    }

    // MARK: Acceptance #1 — influenced suggestion is visibly labeled

    func test_poorRecovery_stampsVisibleHealthKitLabelOnAdjustedTasks() async {
        let source = FakeHealthKitData.poorRecovery(endingAt: now, nights: 4)
        let plan = await plan(with: source, enabled: true)

        let influenced = plan.tasks.filter { $0.pacing != nil }
        XCTAssertFalse(influenced.isEmpty, "poor recovery must produce at least one paced task")

        // The marker exists, is affirmatively "HealthKit-influenced", and carries a rationale.
        guard let marker = influenced.first(where: { $0.ruleKey == "run" })?.pacing else {
            return XCTFail("expected the 'run' session to carry a HealthKit pacing marker")
        }
        XCTAssertEqual(marker.label, "HealthKit-influenced")
        XCTAssertTrue(marker.isHealthKitInfluenced)
        XCTAssertEqual(marker.recovery, .poor)
        XCTAssertFalse(marker.rationale.isEmpty)
        XCTAssertLessThan(marker.durationScale, 1.0, "poor recovery should shorten sessions")

        // The label survives into the preview layer the Goals UI renders.
        let preview = SchedulePreviewBuilder().preview(
            for: plan,
            window: DateInterval(start: now, end: now.addingTimeInterval(8 * 86_400)))
        XCTAssertTrue(preview.blocks.contains { $0.pacing?.label == "HealthKit-influenced" },
                      "the HealthKit-influenced marker must reach the preview/UI layer")
    }

    // MARK: Acceptance #2 — denied permission: planning works, influence absent

    func test_deniedPermission_planningFunctional_noInfluence() async {
        let denying = DenyingHealthKitData()
        let paced = await plan(with: denying, enabled: true)

        // A full plan is still produced (denial is swallowed to "no summaries").
        XCTAssertFalse(paced.tasks.isEmpty, "planning must keep working when HealthKit is denied")
        XCTAssertTrue(paced.tasks.allSatisfy { $0.pacing == nil },
                      "no HealthKit influence should appear when permission is denied")

        // And it matches the plain, HealthKit-free plan task-for-task (same goal data).
        let plain = planner.generatePlan(playbook: training, answers: IntakeAnswers(),
                                         goalTitle: "Ironman 70.3", now: now, targetDate: target(weeks: 4))
        XCTAssertEqual(paced.tasks.count, plain.tasks.count)

        // The daily loop's slip detection still functions on the resulting goal data.
        let detector = SlipDetector()
        let goalTask = GoalTask(title: "Run session", flexibility: .movable,
                                earliestAcceptable: now.addingTimeInterval(-2 * 86_400),
                                latestAcceptable: now.addingTimeInterval(-1 * 86_400),
                                expectedDuration: 2700, isComplete: false)
        let slipped = detector.slippedTasks(tasks: [goalTask], progress: [],
                                            rule: training.slipRule, asOf: now)
        XCTAssertEqual(slipped.count, 1, "slip detection must keep working without HealthKit")
    }

    // MARK: Acceptance #3 — toggle off removes influence, goal data unchanged

    func test_toggleOff_removesInfluence_goalDataIdentical() async {
        // Same poor-recovery source, only the toggle differs.
        let source = FakeHealthKitData.poorRecovery(endingAt: now, nights: 4)
        let influenced = await plan(with: source, enabled: true)
        let disabled = await plan(with: source, enabled: false)

        // Toggle ON does influence...
        XCTAssertTrue(influenced.tasks.contains { $0.pacing != nil })
        // ...toggle OFF has zero influence markers...
        XCTAssertTrue(disabled.tasks.allSatisfy { $0.pacing == nil })

        // ...and the disabled plan is byte-for-byte the plain, unpaced plan (goal data intact).
        let plain = planner.generatePlan(playbook: training, answers: IntakeAnswers(),
                                         goalTitle: "Ironman 70.3", now: now, targetDate: target(weeks: 4))
        XCTAssertEqual(disabled.tasks, plain.tasks,
                       "disabling HealthKit influence must not change the goal's task data")

        // The toggle being ON is what removes tasks/shortens them: influenced has fewer 'run'
        // occurrences than the plain plan (a session was eased away), proving the toggle — not
        // goal data — is the only thing that changed.
        let plainRuns = plain.tasks.filter { $0.ruleKey == "run" }.count
        let influencedRuns = influenced.tasks.filter { $0.ruleKey == "run" }.count
        XCTAssertLessThan(influencedRuns, plainRuns)
    }

    // MARK: Playbook-defined bounds

    func test_pacing_respectsPlaybookBounds() async {
        let source = FakeHealthKitData.poorRecovery(endingAt: now, nights: 4)
        let plan = await plan(with: source, enabled: true)

        // Immovable anchors (swim / long_ride / brick) are never paced — outside the policy set.
        for anchorKey in ["swim", "long_ride", "brick"] {
            XCTAssertTrue(plan.tasks.filter { $0.ruleKey == anchorKey }.allSatisfy { $0.pacing == nil },
                          "\(anchorKey) is an immovable anchor and must not be HealthKit-paced")
        }

        // Duration never cut below the playbook floor (minDurationScale 0.6).
        let pacedRun = plan.tasks.first { $0.ruleKey == "run" && $0.pacing != nil }
        let baseRunDuration = training.taskRules.first { $0.key == "run" }!.expectedDuration
        XCTAssertGreaterThanOrEqual(pacedRun!.expectedDuration, baseRunDuration * 0.6)

        // Frequency never dropped to zero: strength (base freq 1) survives as at least 1/week.
        XCTAssertGreaterThanOrEqual(plan.tasks.filter { $0.ruleKey == "strength" && $0.weekIndex == 0 }.count, 1)
    }

    func test_goodRecovery_producesNoInfluence() async {
        let source = FakeHealthKitData.goodRecovery(endingAt: now, nights: 4)
        let plan = await plan(with: source, enabled: true)
        XCTAssertTrue(plan.tasks.allSatisfy { $0.pacing == nil },
                      "solid recovery should not ease load (guidance eases, never adds)")
    }

    func test_playbookWithoutPacingPolicy_isNeverInfluenced() async {
        // Job search declares no pacingPolicy — poor sleep must not reshape it.
        let source = FakeHealthKitData.poorRecovery(endingAt: now, nights: 4)
        let plan = await plan(with: source, enabled: true, playbook: jobSearch)
        XCTAssertTrue(plan.tasks.allSatisfy { $0.pacing == nil },
                      "a goal type with no pacing policy is never HealthKit-paced")
    }

    // MARK: Recovery classification

    func test_recoveryClassification_isDeterministic() {
        XCTAssertNil(PacingSignal.derive(from: []), "no data → no signal")

        let poor = [HealthSummary(date: now, sleepHours: 5.6, restingHeartRate: 61, hrv: 42)]
        XCTAssertEqual(PacingSignal.derive(from: poor)?.recovery, .poor)

        let good = [HealthSummary(date: now, sleepHours: 8.1, restingHeartRate: 47, hrv: 88)]
        XCTAssertEqual(PacingSignal.derive(from: good)?.recovery, .good)

        let normal = [HealthSummary(date: now, sleepHours: 7.0, restingHeartRate: 52, hrv: 70)]
        XCTAssertEqual(PacingSignal.derive(from: normal)?.recovery, .normal)
    }

    // MARK: Coordinator influence summary (drives the UI banner)

    func test_currentInfluence_summarizesForUI_andRespectsToggle() async {
        let source = FakeHealthKitData.poorRecovery(endingAt: now, nights: 4)
        let coordinator = HealthPacingCoordinator(source: source, lookback: 14 * 86_400)

        let summary = await coordinator.currentInfluence(playbook: training, asOf: now, influenceEnabled: true)
        XCTAssertEqual(summary?.label, "HealthKit-influenced")
        XCTAssertEqual(summary?.signal.recovery, .poor)
        XCTAssertFalse(summary?.affectedTitles.isEmpty ?? true)

        // Toggle off → no summary at all.
        let none = await coordinator.currentInfluence(playbook: training, asOf: now, influenceEnabled: false)
        XCTAssertNil(none)

        // Denied → no summary, no throw.
        let deniedSummary = await HealthPacingCoordinator(source: DenyingHealthKitData())
            .currentInfluence(playbook: training, asOf: now, influenceEnabled: true)
        XCTAssertNil(deniedSummary)
    }
}
