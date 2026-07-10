import XCTest
import SwiftData
import Core
import Data
import Integrations
import Fixtures
@testable import Proposals

/// # Phase 7A — concurrent approval across two synced devices
///
/// The sync scenario the plan calls out: a `create_agent_calendar_event` Proposal syncs to both
/// the iPhone and the Mac, and the user approves it on **both** before sync converges (or approves
/// on A while B still shows it pending). Each device runs its own `ProposalEngine` over its own
/// `ModelContext` — but they write to the **same** Google agent calendar (the calendar lives in
/// Google, not CloudKit). The safety net is Phase 2's idempotent write path: both approvals carry
/// the same caller-provided event ID, so the shared calendar collapses them into exactly one event.
///
/// This proves double-execution under sync is harmless — the core reason the "propose, don't
/// auto-act" model stays safe once two devices are in play.
@MainActor
final class SyncApprovalTests: XCTestCase {

    func test_sameProposalApprovedOnTwoDevices_producesExactlyOneEvent() async throws {
        let clock = FakeClock(now: PX.now)

        // Two independent devices: separate contexts/engines, one shared Google calendar backend.
        let ctxA = try PX.context()
        let ctxB = try PX.context()
        let sharedCalendar = FakeGoogleCalendarAPI()
        let engineA = ProposalEngine(context: ctxA, clock: clock, calendar: sharedCalendar)
        let engineB = ProposalEngine(context: ctxB, clock: clock, calendar: sharedCalendar)

        // The SAME proposal, as it appears on each device after sync (same idempotency key).
        let taskID = UUID()
        let key = ScheduleProposalBuilder.idempotencyKey(forTaskAppID: taskID)
        func proposalCopy() -> Proposal {
            let payload = CreateAgentCalendarEventPayload(
                title: "Long ride", start: PX.now + PX.hour, end: PX.now + 3 * PX.hour, idempotencyKey: key)
            return PX.pending(.createAgentCalendarEvent, payload: payload,
                              factKey: "proposal:create_event:\(key)")
        }
        let onA = proposalCopy()
        let onB = proposalCopy()
        try engineA.enqueue(onA)
        try engineB.enqueue(onB)

        // Both devices approve concurrently (before sync would have marked the other approved).
        _ = try await engineA.approve(onA)
        _ = try await engineB.approve(onB)

        // Exactly one calendar event despite two approvals — idempotent event ID did its job.
        XCTAssertEqual(sharedCalendar.createdEvents.count, 1,
                       "two devices approving the same proposal must yield exactly one event")
        XCTAssertEqual(sharedCalendar.writeCallCount, 2,
                       "both devices attempted the write; the idempotent key deduped, not the caller")
        XCTAssertTrue(sharedCalendar.createdEvents.allSatisfy { $0.event.isAgentOwned })

        // Each device locally marked its own copy approved (its own state machine advanced).
        XCTAssertEqual(onA.status, .approved)
        XCTAssertEqual(onB.status, .approved)
    }
}
