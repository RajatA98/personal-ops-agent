import XCTest
import SwiftData
import Core
import Data
import Goals
import Integrations
import Fixtures
@testable import Proposals

/// Approving a `create_agent_calendar_event` Proposal built from a Phase 3A goal-plan preview
/// results in exactly one agent-calendar event via Phase 2's idempotent write path.
@MainActor
final class CalendarProposalTests: XCTestCase {

    /// Build a real Phase 3A plan, materialize it (so tasks have stable appIDs), build the
    /// preview + the create-event proposals, approve them, and assert the fake calendar wrote
    /// exactly one event per task — each on the agent calendar with the task-seeded idempotency key.
    func test_approvingPreviewProposals_createsExactlyOneEventEach_idempotent() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)

        // Phase 3A: generate + materialize a training plan → persisted GoalTasks with appIDs.
        let playbook = PlaybookLibrary.playbook(forKey: "training")!
        let plan = GoalPlanner().generatePlan(
            playbook: playbook, answers: IntakeAnswers(), goalTitle: "Ironman 70.3",
            now: PX.now, targetDate: PX.now + 14 * PX.day)
        let goal = try GoalPlanMaterializer(store: store).persist(plan, now: PX.now)
        let tasks = goal.tasks ?? []
        XCTAssertFalse(tasks.isEmpty)

        // The preview (Phase 3A) and the proposals are built from the same tasks.
        let preview = SchedulePreviewBuilder().preview(for: plan)
        XCTAssertFalse(preview.isEmpty)

        // Only tasks scheduled in the preview window matter for a like-for-like count; build
        // proposals for the tasks that fall in that first-week window.
        let windowTasks = tasks.filter {
            guard let s = $0.earliestAcceptable else { return false }
            return preview.window.contains(s)
        }
        let proposals = ScheduleProposalBuilder().proposals(
            forTasks: windowTasks, goalTitle: goal.title, now: PX.now)
        XCTAssertEqual(proposals.count, windowTasks.count)

        let fakeCalendar = FakeGoogleCalendarAPI()
        let eng = ProposalEngine(context: ctx, clock: clock, calendar: fakeCalendar)
        for p in proposals { try eng.enqueue(p) }

        // Approve the whole batch.
        let receipts = try await eng.approveBatch(proposals)
        XCTAssertEqual(receipts.count, proposals.count)

        // Exactly one event per task, all on the agent calendar, keyed by the task appID.
        XCTAssertEqual(fakeCalendar.createdEvents.count, windowTasks.count)
        XCTAssertTrue(fakeCalendar.createdEvents.allSatisfy { $0.event.calendarID == FakeGoogleCalendarAPI.agentCalendarID })
        XCTAssertTrue(fakeCalendar.createdEvents.allSatisfy { $0.event.isAgentOwned })
        let expectedKeys = Set(windowTasks.map { ScheduleProposalBuilder.idempotencyKey(forTaskAppID: $0.appID) })
        XCTAssertEqual(Set(fakeCalendar.createdEvents.map { $0.idempotencyKey }), expectedKeys)
    }

    /// Idempotency: two proposals with the same task-seeded key (e.g. a re-derived batch)
    /// approve to exactly ONE event.
    func test_duplicateKey_yieldsExactlyOneEvent() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let fakeCalendar = FakeGoogleCalendarAPI()
        let eng = ProposalEngine(context: ctx, clock: clock, calendar: fakeCalendar)

        let taskID = UUID()
        let key = ScheduleProposalBuilder.idempotencyKey(forTaskAppID: taskID)
        func makeProposal(factSuffix: String) -> Proposal {
            let payload = CreateAgentCalendarEventPayload(
                title: "Long ride", start: PX.now + PX.hour, end: PX.now + 3 * PX.hour, idempotencyKey: key)
            return PX.pending(.createAgentCalendarEvent, payload: payload,
                              factKey: "proposal:create_event:\(key):\(factSuffix)")
        }
        let first = makeProposal(factSuffix: "a")
        let second = makeProposal(factSuffix: "b")
        try eng.enqueue(first)
        try eng.enqueue(second)

        _ = try await eng.approve(first)
        _ = try await eng.approve(second)

        XCTAssertEqual(fakeCalendar.createdEvents.count, 1, "same idempotency key → exactly one event")
        XCTAssertEqual(fakeCalendar.writeCallCount, 2, "both approvals attempted a write; the store deduped")
    }

    /// A create-event approval with no calendar configured fails and leaves the proposal pending.
    func test_createEvent_noCalendar_throws_leavesPending() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let eng = ProposalEngine(context: ctx, clock: clock, calendar: nil)

        let payload = CreateAgentCalendarEventPayload(
            title: "x", start: PX.now, end: PX.now + PX.hour, idempotencyKey: "goaltask:\(UUID().uuidString)")
        let p = PX.pending(.createAgentCalendarEvent, payload: payload)
        try eng.enqueue(p)

        await XCTAssertThrowsErrorAsync(try await eng.approve(p)) { error in
            XCTAssertEqual(error as? ProposalError, .integrationUnavailable)
        }
        XCTAssertEqual(p.status, .pending)
    }
}
