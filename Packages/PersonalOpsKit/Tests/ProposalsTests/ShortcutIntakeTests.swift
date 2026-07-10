import XCTest
import SwiftData
import Core
import Data
import Integrations
import Fixtures
@testable import Proposals

/// Phase 4C acceptance #2 & #3: a Shortcut-forwarded text produces a *classified pending*
/// Proposal (never a silent write), and a malformed / empty / delayed payload is dropped with
/// no Proposal (never guessed into memory).
@MainActor
final class ShortcutIntakeTests: XCTestCase {

    private func makeService(ctx: ModelContext, clock: FakeClock,
                             log: ((String) -> Void)? = nil) -> (ShortcutIntakeService, ProposalEngine) {
        let engine = ProposalEngine(context: ctx, clock: clock)
        let service = ShortcutIntakeService(engine: engine, log: log)
        return (service, engine)
    }

    // MARK: - Valid text → classified pending Proposal

    /// A plan-ish text with a concrete date + time is classified as a create-event Proposal,
    /// pending, tagged with the untrusted iMessage source — and nothing is written directly.
    func test_forwardedEventText_producesPendingCreateEventProposal() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let (service, engine) = makeService(ctx: ctx, clock: clock)

        let outcome = try service.ingest(
            text: "Dinner with Sam on 2027-03-05 at 7pm",
            receivedAt: PX.now, now: PX.now)

        guard case .enqueued(_, let type) = outcome else {
            return XCTFail("expected enqueued, got \(outcome)")
        }
        XCTAssertEqual(type, .createAgentCalendarEvent)

        let pending = try engine.pendingProposals()
        XCTAssertEqual(pending.count, 1)
        let p = try XCTUnwrap(pending.first)
        XCTAssertEqual(p.status, .pending)          // pending, never auto-executed
        XCTAssertEqual(p.source, .iMessage)          // explicit untrusted provenance
        XCTAssertLessThan(p.confidence, 0.5)         // low-confidence untrusted source
    }

    /// Valid text with no schedulable date/time is still classified — as a remember-note
    /// Proposal — so it surfaces for review rather than being dropped or silently written.
    func test_forwardedNoteText_producesPendingRememberProposal() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let (service, engine) = makeService(ctx: ctx, clock: clock)

        let outcome = try service.ingest(
            text: "Remember the garage door code is 4417", receivedAt: PX.now, now: PX.now)

        guard case .enqueued(_, let type) = outcome else {
            return XCTFail("expected enqueued, got \(outcome)")
        }
        XCTAssertEqual(type, .rememberFact)
        XCTAssertEqual(try engine.pendingProposals().count, 1)
        XCTAssertEqual(try engine.pendingProposals().first?.source, .iMessage)
    }

    /// The same message forwarded twice does not stack two proposals (stable text key).
    func test_duplicateForward_dedupesViaFactKey() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let (service, engine) = makeService(ctx: ctx, clock: clock)

        let first = try service.ingest(text: "Standup on 2027-04-01 at 9am", receivedAt: PX.now, now: PX.now)
        // Second identical forward collapses onto the first pending item (same stable factKey).
        let second = try service.ingest(text: "Standup on 2027-04-01 at 9am", receivedAt: PX.now, now: PX.now)

        let pendingForFact = try engine.pendingProposals()
            .filter { $0.factKey.hasPrefix("proposal:imessage:") }
        XCTAssertEqual(pendingForFact.count, 1)              // exactly one pending item
        XCTAssertEqual(first, second)                        // both resolve to the same proposal
    }

    // MARK: - Dropped payloads → NO Proposal

    /// Empty / whitespace-only text is dropped with no Proposal.
    func test_emptyPayload_droppedNoProposal() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let (service, engine) = makeService(ctx: ctx, clock: clock)

        XCTAssertEqual(try service.ingest(text: "   \n  ", receivedAt: PX.now, now: PX.now),
                       .dropped(.empty))
        XCTAssertEqual(try service.ingest(text: nil, receivedAt: PX.now, now: PX.now),
                       .dropped(.empty))
        XCTAssertTrue(try engine.pendingProposals().isEmpty)
    }

    /// A delayed payload (receivedAt older than maxAge) is dropped as stale — never guessed
    /// into memory.
    func test_delayedPayload_droppedAsStale() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let (service, engine) = makeService(ctx: ctx, clock: clock)

        let twoDaysAgo = PX.now.addingTimeInterval(-2 * 86_400)
        let outcome = try service.ingest(
            text: "Lunch on 2027-03-05 at noon", receivedAt: twoDaysAgo, now: PX.now)
        XCTAssertEqual(outcome, .dropped(.stale))
        XCTAssertTrue(try engine.pendingProposals().isEmpty)
    }

    /// An implausible future timestamp is treated as malformed and dropped.
    func test_futureTimestamp_droppedAsFuture() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let (service, engine) = makeService(ctx: ctx, clock: clock)

        let outcome = try service.ingest(
            text: "Something", receivedAt: PX.now.addingTimeInterval(3600), now: PX.now)
        XCTAssertEqual(outcome, .dropped(.future))
        XCTAssertTrue(try engine.pendingProposals().isEmpty)
    }

    /// Dropped payloads log a metadata-only line and never the raw text (Local-only privacy).
    func test_droppedPayload_logsMetadataNotContent() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        var lines: [String] = []
        let (service, _) = makeService(ctx: ctx, clock: clock) { lines.append($0) }

        _ = try service.ingest(text: "   ", receivedAt: PX.now, now: PX.now)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.contains("dropped") })
    }
}
