import XCTest
import SwiftData
import Core
import Data
import DailyLoop
import Integrations
import Fixtures
@testable import Proposals

/// A fixture Weekly Review produces a batch of next-week Proposals; batch-approving creates
/// exactly the approved events, and dismissing individual items excludes only those.
@MainActor
final class WeeklyReviewBatchTests: XCTestCase {

    private func briefingTask(_ title: String, start: Date) -> BriefingTask {
        BriefingTask(taskID: UUID(), goalID: UUID(), goalTitle: "g", title: title,
                     flexibility: .movable, priority: 1,
                     earliestAcceptable: start, latestAcceptable: start + PX.hour, isComplete: false)
    }

    private func fixtureReview() -> WeeklyReview {
        let training = WeeklyGoalRollup(
            goalID: UUID(), goalTitle: "Ironman", completed: [], slipped: [],
            nextWeek: [briefingTask("Swim", start: PX.now + PX.day),
                       briefingTask("Long ride", start: PX.now + 2 * PX.day)])
        let jobs = WeeklyGoalRollup(
            goalID: UUID(), goalTitle: "Job search", completed: [], slipped: [],
            nextWeek: [briefingTask("Apply x5", start: PX.now + 3 * PX.day)])
        return WeeklyReview(weekStart: PX.now - 7 * PX.day, weekEnd: PX.now,
                            goals: [training, jobs], degradedSources: [])
    }

    func test_weeklyReview_batchApprove_createsExactlyApprovedEvents() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let fakeCalendar = FakeGoogleCalendarAPI()
        let eng = ProposalEngine(context: ctx, clock: clock, calendar: fakeCalendar)

        let proposals = WeeklyReviewProposalBuilder().nextWeekProposals(from: fixtureReview(), now: PX.now)
        XCTAssertEqual(proposals.count, 3, "one per next-week task across both goals")
        for p in proposals { try eng.enqueue(p) }
        XCTAssertEqual(try eng.pendingProposals().count, 3)

        let receipts = try await eng.approveBatch(proposals)
        XCTAssertEqual(receipts.count, 3)
        XCTAssertEqual(fakeCalendar.createdEvents.count, 3, "exactly the three approved events")
        XCTAssertTrue(try eng.pendingProposals().isEmpty)
    }

    func test_weeklyReview_dismissingOneItem_excludesOnlyThat() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let fakeCalendar = FakeGoogleCalendarAPI()
        let eng = ProposalEngine(context: ctx, clock: clock, calendar: fakeCalendar)

        let proposals = WeeklyReviewProposalBuilder().nextWeekProposals(from: fixtureReview(), now: PX.now)
        for p in proposals { try eng.enqueue(p) }

        // Dismiss the middle one individually.
        let dropped = proposals[1]
        try eng.dismiss(dropped)
        XCTAssertEqual(dropped.status, .dismissed)

        // Batch-approve the remaining pending ones.
        let remaining = try eng.pendingProposals()
        XCTAssertEqual(remaining.count, 2)
        _ = try await eng.approveBatch(remaining)

        XCTAssertEqual(fakeCalendar.createdEvents.count, 2, "only the two non-dismissed events were created")
        // The dismissed one never wrote a calendar event.
        let droppedKey = fakeCalendar.createdEvents.map { $0.idempotencyKey }
        let droppedPayload = try ProposalPayloadCoder.decode(CreateAgentCalendarEventPayload.self, from: dropped.payload)
        XCTAssertFalse(droppedKey.contains(droppedPayload.idempotencyKey))
    }

    /// Re-running the builder + enqueueBatch does not duplicate: the stable per-task factKey is
    /// deduped, so a second Sunday pass adds nothing already pending.
    func test_enqueueBatch_dedupesByFactKey() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let eng = ProposalEngine(context: ctx, clock: clock, calendar: FakeGoogleCalendarAPI())
        let review = fixtureReview()

        let first = try eng.enqueueBatch(WeeklyReviewProposalBuilder().nextWeekProposals(from: review, now: PX.now))
        XCTAssertEqual(first.count, 3)
        // Re-derive from the same review (same task IDs → same factKeys) and enqueue again.
        let second = try eng.enqueueBatch(WeeklyReviewProposalBuilder().nextWeekProposals(from: review, now: PX.now))
        XCTAssertEqual(second.count, 0, "already-pending proposals are not duplicated")
        XCTAssertEqual(try eng.pendingProposals().count, 3)
    }
}
