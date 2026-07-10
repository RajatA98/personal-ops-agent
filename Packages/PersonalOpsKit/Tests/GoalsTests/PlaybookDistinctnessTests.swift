import XCTest
import Core
import Fixtures
@testable import Goals

/// Acceptance #1: creating a Training goal and a Job Search goal from their playbooks
/// produces *genuinely distinct* plans **from a shared schema** — the differences are
/// driven by playbook data, not by branches in the engine.
///
/// Every test here drives the exact same `GoalPlanner.generatePlan(...)` call for both
/// goals, differing only in which `GoalPlaybook` value is passed. If distinctness came from
/// hardcoded code paths rather than data, these assertions could not hold while the engine
/// stayed single-path.
final class PlaybookDistinctnessTests: XCTestCase {

    private let planner = GoalPlanner()
    private let clock = FakeClock(now: Date(timeIntervalSince1970: 0))

    private func plan(_ playbook: GoalPlaybook, title: String) -> GeneratedPlan {
        planner.generatePlan(
            playbook: playbook,
            answers: IntakeAnswers(),
            goalTitle: title,
            now: clock.now,
            targetDate: clock.now.addingTimeInterval(8 * 7 * 86_400)) // 8-week horizon
    }

    func test_bothPlansComeFromTheSameEngineEntryPoint() {
        // Sanity: identical call, only the playbook differs. (Documents the shared path.)
        let training = plan(.init(from: PlaybookLibrary.triathlonTraining), title: "Ironman 70.3")
        let jobs = plan(.init(from: PlaybookLibrary.jobSearch), title: "Land PM role")
        XCTAssertFalse(training.tasks.isEmpty)
        XCTAssertFalse(jobs.tasks.isEmpty)
    }

    func test_flexibilityMix_differsByData() {
        let training = plan(PlaybookLibrary.triathlonTraining, title: "Ironman 70.3")
        let jobs = plan(PlaybookLibrary.jobSearch, title: "Land PM role")

        let trainingFixed = training.tasks.filter { $0.flexibility == .fixed }
        let jobsFixed = jobs.tasks.filter { $0.flexibility == .fixed }

        // Training is anchored by immovable workouts; a job search bulldozes nothing.
        XCTAssertGreaterThan(trainingFixed.count, 0, "training should have fixed anchor workouts")
        XCTAssertEqual(jobsFixed.count, 0, "job search should have no fixed/immovable blocks")
    }

    func test_conflictPolicyMix_differsByData() {
        let training = plan(PlaybookLibrary.triathlonTraining, title: "Ironman 70.3")
        let jobs = plan(PlaybookLibrary.jobSearch, title: "Land PM role")

        // Training uses `.block` (a booked pool lane must win); job search never blocks.
        XCTAssertTrue(training.tasks.contains { $0.conflictPolicy == .block })
        XCTAssertFalse(jobs.tasks.contains { $0.conflictPolicy == .block })
    }

    func test_progressSignals_areDisjointMetricSets() {
        let trainingMetrics = Set(PlaybookLibrary.triathlonTraining.progressSignals.map(\.metricKey))
        let jobMetrics = Set(PlaybookLibrary.jobSearch.progressSignals.map(\.metricKey))
        XCTAssertTrue(trainingMetrics.isDisjoint(with: jobMetrics),
                      "the two goal types track entirely different metrics")
        XCTAssertTrue(trainingMetrics.contains("weekly_swim_km"))
        XCTAssertTrue(jobMetrics.contains("applications_sent"))
    }

    func test_milestones_haveDifferentShape() {
        let training = plan(PlaybookLibrary.triathlonTraining, title: "Ironman 70.3")
        let jobs = plan(PlaybookLibrary.jobSearch, title: "Land PM role")

        let trainingKeys = training.milestones.map(\.key)
        let jobKeys = jobs.milestones.map(\.key)
        XCTAssertNotEqual(trainingKeys, jobKeys)
        XCTAssertTrue(trainingKeys.contains("taper"), "training has a taper phase")
        XCTAssertTrue(jobKeys.contains("interviewing"), "job search has an interviewing phase")
    }

    func test_taskVolumeAndTitles_differ() {
        let training = plan(PlaybookLibrary.triathlonTraining, title: "Ironman 70.3")
        let jobs = plan(PlaybookLibrary.jobSearch, title: "Land PM role")

        let trainingTitles = Set(training.tasks.map(\.title))
        let jobTitles = Set(jobs.tasks.map(\.title))
        XCTAssertTrue(trainingTitles.isDisjoint(with: jobTitles))
        // Job search sends far more applications/week than any single training session recurs.
        XCTAssertNotEqual(training.tasks.count, jobs.tasks.count)
    }

    func test_completionCriteria_differByData() {
        // Training completes when its date arrives; a job search completes on an *offer*.
        XCTAssertEqual(PlaybookLibrary.triathlonTraining.completionCriteria, [.targetDateReached])
        XCTAssertTrue(PlaybookLibrary.jobSearch.completionCriteria.contains(
            .metricThreshold(metricKey: "offers_received", atLeast: 1)))
    }
}

// Tiny convenience so the "same entry point" test reads naturally.
private extension GoalPlaybook {
    init(from playbook: GoalPlaybook) { self = playbook }
}
