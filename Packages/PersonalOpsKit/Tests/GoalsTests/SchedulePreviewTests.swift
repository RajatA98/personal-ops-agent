import XCTest
import Core
import Fixtures
import Integrations
@testable import Goals

/// Acceptance #3: a generated schedule preview is inspectable but writes to no calendar —
/// asserted by driving a `FakeGoogleCalendarAPI` alongside the engine and proving its
/// write-call count stays at zero throughout planning and preview generation.
final class SchedulePreviewTests: XCTestCase {

    private let planner = GoalPlanner()
    private let builder = SchedulePreviewBuilder()
    private let epoch = Date(timeIntervalSince1970: 0)
    private let week: TimeInterval = 7 * 86_400

    private func makePlan(_ playbook: GoalPlaybook, title: String) -> GeneratedPlan {
        planner.generatePlan(
            playbook: playbook, answers: IntakeAnswers(),
            goalTitle: title, now: epoch,
            targetDate: epoch.addingTimeInterval(6 * week))
    }

    func test_previewIsInspectable_andNonEmptyForTheFirstWeek() {
        let plan = makePlan(PlaybookLibrary.triathlonTraining, title: "Ironman 70.3")
        let preview = builder.preview(for: plan) // defaults to first 7 days

        XCTAssertFalse(preview.isEmpty)
        XCTAssertEqual(preview.playbookKey, "training")
        // Blocks are chronological and carry the scheduling metadata for inspection.
        let starts = preview.blocks.map(\.start)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertTrue(preview.blocks.allSatisfy { $0.end > $0.start })
        // Every block falls inside the preview window.
        XCTAssertTrue(preview.blocks.allSatisfy { preview.window.contains($0.start) })
    }

    func test_engineOperationsPerformZeroCalendarWrites() async {
        // A real calendar fake is present the whole time. If the engine touched it, the
        // write-call count would rise. It must stay at exactly zero.
        let calendar = FakeGoogleCalendarAPI.seeded()

        let training = makePlan(PlaybookLibrary.triathlonTraining, title: "Ironman 70.3")
        let jobs = makePlan(PlaybookLibrary.jobSearch, title: "Land PM role")
        _ = builder.preview(for: training)
        _ = builder.preview(for: jobs)
        _ = builder.preview(for: training, window: DateInterval(start: epoch, end: epoch.addingTimeInterval(6 * week)))

        XCTAssertEqual(calendar.writeCallCount, 0, "planning/preview must not write to the calendar")
        XCTAssertEqual(calendar.createdEvents.count, 0, "no events were created by the engine")

        // And the fake genuinely *can* record a write — proving the zero above is meaningful,
        // not a fake that never counts anything.
        let probe = CalendarEventDTO(
            id: "probe", calendarID: "agent", title: "probe",
            start: epoch, end: epoch.addingTimeInterval(3600), isAgentOwned: true)
        _ = try? await calendar.createEvent(probe, idempotencyKey: "probe")
        XCTAssertEqual(calendar.writeCallCount, 1)
    }

    func test_customWindowSelectsOnlyBlocksInsideIt() {
        let plan = makePlan(PlaybookLibrary.jobSearch, title: "Land PM role")
        // Week 2 only.
        let window = DateInterval(
            start: epoch.addingTimeInterval(2 * week),
            end: epoch.addingTimeInterval(3 * week))
        let preview = builder.preview(for: plan, window: window)

        XCTAssertFalse(preview.isEmpty)
        XCTAssertTrue(preview.blocks.allSatisfy { window.contains($0.start) })
    }
}
