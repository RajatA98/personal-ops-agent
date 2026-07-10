import XCTest
import Core
import Data
import Fixtures
@testable import Goals

/// Acceptance #2: slip detection correctly flags a `GoalTask` as slipped given fixture data
/// showing no completion evidence — and, symmetrically, does *not* flag tasks that are done,
/// still within their window, or backed by progress evidence.
final class SlipDetectorTests: XCTestCase {

    private let detector = SlipDetector()
    private let clock = FakeClock(now: Date(timeIntervalSince1970: 10 * 86_400))
    private let rule = PlaybookLibrary.triathlonTraining.slipRule // 12h grace, evidence required

    private func task(
        title: String,
        earliest: Date,
        latest: Date?,
        complete: Bool = false
    ) -> GoalTask {
        GoalTask(
            title: title,
            flexibility: .fixed,
            earliestAcceptable: earliest,
            latestAcceptable: latest,
            expectedDuration: 3600,
            isComplete: complete)
    }

    func test_flagsTaskPastWindowWithNoCompletionEvidence() {
        // A task whose window closed two days ago, with no logged progress. Slipped.
        let earliest = clock.now.addingTimeInterval(-3 * 86_400)
        let latest = clock.now.addingTimeInterval(-2 * 86_400)
        let overdue = task(title: "Missed swim", earliest: earliest, latest: latest)

        let slipped = detector.slippedTasks(
            tasks: [overdue], progress: [], rule: rule, asOf: clock.now)

        XCTAssertEqual(slipped.map(\.title), ["Missed swim"])
    }

    func test_doesNotFlagFutureTask() {
        let earliest = clock.now.addingTimeInterval(2 * 86_400)
        let latest = clock.now.addingTimeInterval(2 * 86_400 + 3600)
        let upcoming = task(title: "Tomorrow's ride", earliest: earliest, latest: latest)

        XCTAssertTrue(detector.slippedTasks(
            tasks: [upcoming], progress: [], rule: rule, asOf: clock.now).isEmpty)
    }

    func test_doesNotFlagCompletedTask() {
        let earliest = clock.now.addingTimeInterval(-3 * 86_400)
        let latest = clock.now.addingTimeInterval(-2 * 86_400)
        let done = task(title: "Done swim", earliest: earliest, latest: latest, complete: true)

        XCTAssertTrue(detector.slippedTasks(
            tasks: [done], progress: [], rule: rule, asOf: clock.now).isEmpty)
    }

    func test_progressEvidenceWithinWindowClearsSlip() {
        let earliest = clock.now.addingTimeInterval(-3 * 86_400)
        let latest = clock.now.addingTimeInterval(-2 * 86_400)
        let overdue = task(title: "Swim", earliest: earliest, latest: latest)

        // A progress entry logged during the window is completion evidence.
        let evidence = GoalProgress(
            createdAt: latest.addingTimeInterval(-1800),
            metricKey: "weekly_swim_km", value: 2)

        XCTAssertTrue(detector.slippedTasks(
            tasks: [overdue], progress: [evidence], rule: rule, asOf: clock.now).isEmpty)
    }

    func test_gracePeriodDelaysSlip() {
        // Latest was 6h ago; the playbook grace is 12h — still inside grace, not slipped yet.
        let earliest = clock.now.addingTimeInterval(-2 * 86_400)
        let latest = clock.now.addingTimeInterval(-6 * 3_600)
        let recentlyDue = task(title: "Evening run", earliest: earliest, latest: latest)

        XCTAssertTrue(detector.slippedTasks(
            tasks: [recentlyDue], progress: [], rule: rule, asOf: clock.now).isEmpty)

        // Advance past the grace window → now it slips.
        let past = clock.now.addingTimeInterval(13 * 3_600)
        XCTAssertEqual(
            detector.slippedTasks(tasks: [recentlyDue], progress: [], rule: rule, asOf: past)
                .map(\.title),
            ["Evening run"])
    }

    func test_openEndedTaskNeverSlips() {
        let openEnded = task(
            title: "Someday strength work",
            earliest: clock.now.addingTimeInterval(-5 * 86_400),
            latest: nil)
        XCTAssertTrue(detector.slippedTasks(
            tasks: [openEnded], progress: [], rule: rule, asOf: clock.now).isEmpty)
    }
}
