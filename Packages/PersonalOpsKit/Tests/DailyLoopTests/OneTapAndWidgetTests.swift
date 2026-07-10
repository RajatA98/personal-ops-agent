import XCTest
import SwiftData
import Core
import Data
import Goals
import Integrations
import Fixtures
@testable import DailyLoop

/// Phase 3B acceptance #5: the widget renders the fixture headline; a one-tap complete/skip on
/// a fixture `GoalTask` updates `GoalProgress` and is reflected in the next briefing assembly.
final class OneTapAndWidgetTests: XCTestCase {

    private let assembler = BriefingAssembler()

    private func metricKey() -> String {
        PlaybookLibrary.triathlonTraining.progressSignals[0].metricKey
    }

    // One-tap complete updates GoalProgress AND is reflected in the next briefing.
    func test_oneTapCompleteUpdatesProgressAndReflectsInNextBriefing() throws {
        let ctx = try DL.context()
        let store = MemoryStore(context: ctx)

        let swim = DL.task(title: "Swim session", earliest: DL.now.addingTimeInterval(8 * DL.hour),
                           latest: DL.now.addingTimeInterval(9 * DL.hour), priority: 3)
        let goal = try DL.insertGoal(into: ctx, tasks: [swim])

        func brief() -> MorningBriefing {
            assembler.assemble(
                now: DL.now, calendar: DL.utc, calendarEvents: [],
                calendarFreshness: DL.freshCalendar(), gmailFreshness: DL.absentGmail(),
                healthFreshness: DL.withheldHealth(),
                goals: [BriefingGoalInput(goal: goal)], yesterday: nil, openLoops: [])
        }

        // Before: the swim is due.
        XCTAssertEqual(brief().dueTasks.map(\.title), ["Swim session"])
        XCTAssertTrue(try store.all(GoalProgress.self).isEmpty)

        // One tap: complete.
        try TaskActioner(store: store).complete(
            task: swim, goal: goal, metricKey: metricKey(), value: 3, now: DL.now)

        // GoalProgress updated.
        let progress = try store.all(GoalProgress.self)
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.metricKey, metricKey())
        XCTAssertEqual(progress.first?.value, 3)

        // Reflected in the next briefing: the completed task drops out of due tasks.
        XCTAssertTrue(brief().dueTasks.isEmpty)
        XCTAssertTrue(swim.isComplete)
    }

    // One-tap skip writes a GoalProgress note without completing the task.
    func test_oneTapSkipWritesProgressWithoutCompleting() throws {
        let ctx = try DL.context()
        let store = MemoryStore(context: ctx)
        let ride = DL.task(title: "Recovery ride",
                           earliest: DL.now.addingTimeInterval(8 * DL.hour),
                           latest: DL.now.addingTimeInterval(9 * DL.hour))
        let goal = try DL.insertGoal(into: ctx, tasks: [ride])

        try TaskActioner(store: store).skip(
            task: ride, goal: goal, metricKey: metricKey(), now: DL.now)

        let progress = try store.all(GoalProgress.self)
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.value, 0)
        XCTAssertFalse(ride.isComplete)
    }

    // Widget renders the fixture headline (top priority + slip count) from a briefing.
    func test_widgetRendersFixtureHeadline() throws {
        let ctx = try DL.context()

        let due = DL.task(title: "Swim session", earliest: DL.now.addingTimeInterval(8 * DL.hour),
                          latest: DL.now.addingTimeInterval(9 * DL.hour), priority: 3)
        let slipped = DL.task(title: "Missed ride",
                              earliest: DL.now.addingTimeInterval(-3 * DL.day),
                              latest: DL.now.addingTimeInterval(-2 * DL.day))
        let goal = try DL.insertGoal(into: ctx, tasks: [due, slipped])

        let briefing = assembler.assemble(
            now: DL.now, calendar: DL.utc, calendarEvents: [],
            calendarFreshness: DL.freshCalendar(), gmailFreshness: DL.absentGmail(),
            healthFreshness: DL.withheldHealth(),
            goals: [BriefingGoalInput(goal: goal)], yesterday: nil, openLoops: [])

        let snapshot = WidgetSnapshot.from(briefing)
        XCTAssertEqual(snapshot.topPriorityTitle, "Swim session")
        XCTAssertEqual(snapshot.slipCount, 1)
        XCTAssertEqual(snapshot.headline, "Swim session")
        XCTAssertEqual(snapshot.slipLine, "1 slipping")

        // Shared-store round-trip (the app writes; the widget reads).
        let suite = "test.\(UUID().uuidString)"
        let store = WidgetSnapshotStore(defaults: UserDefaults(suiteName: suite))
        store.write(snapshot)
        XCTAssertEqual(store.read(), snapshot)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // With no snapshot written, the widget store degrades to the placeholder (never fails).
    func test_widgetStoreFallsBackToPlaceholder() {
        let store = WidgetSnapshotStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        XCTAssertEqual(store.read(), .placeholder)
    }
}
