import XCTest
import SwiftData
import Core
import Data
import Goals
import Fixtures
@testable import DailyLoop

/// Phase 3B acceptance #3: Evening Capture updates `DailyLog`, `GoalProgress`, and `OpenLoop`
/// from a scripted text/tap interaction — asserted by reading the changes back through the
/// store (not the View).
final class EveningCaptureTests: XCTestCase {

    private func metricKey() -> String {
        PlaybookLibrary.triathlonTraining.progressSignals[0].metricKey // "weekly_swim_km"
    }

    func test_captureWritesDailyLogProgressAndOpenLoop() throws {
        let ctx = try DL.context()
        let clock = FakeClock(now: DL.now)
        let store = MemoryStore(context: ctx, clock: clock)

        let swim = DL.task(title: "Swim", earliest: DL.now.addingTimeInterval(8 * DL.hour),
                           latest: DL.now.addingTimeInterval(9 * DL.hour))
        let strength = DL.task(title: "Strength", earliest: DL.now.addingTimeInterval(9 * DL.hour),
                               latest: DL.now.addingTimeInterval(10 * DL.hour))
        let goal = try DL.insertGoal(into: ctx, tasks: [swim, strength])

        let capture = EveningCapture(store: store, calendar: DL.utc)
        let input = CaptureInput(
            note: "Good day — swam long, skipped strength.",
            completed: [TaskOutcome(task: swim, goal: goal, metricKey: metricKey(), value: 2.5)],
            skipped: [TaskOutcome(task: strength, goal: goal, metricKey: metricKey())],
            progressMarks: [],
            openLoops: [OpenLoopDraft(title: "Book massage", detail: "Legs are toast")])

        let result = try capture.apply(input, now: DL.now)

        // DailyLog written for today.
        XCTAssertTrue(result.dailyLogWritten)
        let logKey = EveningCapture.dayFactKey(for: DL.now, calendar: DL.utc)
        let log = try store.resolve(DailyLog.self, factKey: logKey, asOf: DL.now).value
        XCTAssertEqual(log?.summary, "Good day — swam long, skipped strength.")

        // GoalProgress: one completion (value 2.5) + one skip (value 0).
        let progress = try store.all(GoalProgress.self)
        XCTAssertEqual(progress.count, 2)
        XCTAssertTrue(progress.contains { $0.value == 2.5 })
        XCTAssertTrue(progress.contains { $0.value == 0 })

        // Reconciliation: the completed task is now marked done; the skipped one is not.
        XCTAssertTrue(swim.isComplete)
        XCTAssertFalse(strength.isComplete)

        // OpenLoop written.
        let loops = try store.all(OpenLoop.self)
        XCTAssertEqual(loops.map(\.title), ["Book massage"])
    }

    func test_secondCaptureSameDayRevisesDailyLogRatherThanDuplicating() throws {
        let ctx = try DL.context()
        let clock = FakeClock(now: DL.now)
        let store = MemoryStore(context: ctx, clock: clock)
        let capture = EveningCapture(store: store, calendar: DL.utc)

        _ = try capture.apply(CaptureInput(note: "First pass."), now: DL.now)
        _ = try capture.apply(CaptureInput(note: "Corrected: actually a rest day."),
                              now: DL.now.addingTimeInterval(600))

        let logKey = EveningCapture.dayFactKey(for: DL.now, calendar: DL.utc)
        // Exactly one active revision, carrying the corrected text.
        let resolution = try store.resolve(DailyLog.self, factKey: logKey, asOf: DL.now)
        XCTAssertEqual(resolution.value?.summary, "Corrected: actually a rest day.")
        // History preserves the prior revision (append-only audit layer).
        let history = try store.history(DailyLog.self, factKey: logKey)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.summary, "First pass.")
    }
}
