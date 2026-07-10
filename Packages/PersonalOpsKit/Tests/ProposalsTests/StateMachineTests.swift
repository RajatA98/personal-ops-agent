import XCTest
import SwiftData
import Core
import Data
import Fixtures
@testable import Proposals

/// The safety-critical state machine: what runs, and — more importantly — what NEVER runs.
@MainActor
final class StateMachineTests: XCTestCase {

    private func engine(_ ctx: ModelContext, clock: FakeClock, handlers: [any ProposalHandler]) -> ProposalEngine {
        ProposalEngine(context: ctx, clock: clock, calendar: nil, handlers: handlers)
    }

    /// One spy per type. Approving a proposal of type T runs T's spy exactly once and every
    /// other spy zero times — no inferred follow-up action.
    func test_approve_invokesOnlyItsOwnHandler() async throws {
        for target in ProposalType.allCases {
            let ctx = try PX.context()
            let clock = FakeClock(now: PX.now)
            let spies = ProposalType.allCases.map { SpyHandler($0) }
            let eng = engine(ctx, clock: clock, handlers: spies)

            let proposal = PX.pending(target, payload: ["k": "v"])
            try eng.enqueue(proposal)
            _ = try await eng.approve(proposal)

            for spy in spies {
                if spy.handledType == target {
                    XCTAssertEqual(spy.executeCount, 1, "\(target) handler should run exactly once")
                    XCTAssertEqual(spy.lastProposalAppID, proposal.appID)
                } else {
                    XCTAssertEqual(spy.executeCount, 0,
                                   "approving \(target) must NOT touch the \(spy.handledType) handler")
                }
            }
            XCTAssertEqual(proposal.status, .approved)
        }
    }

    /// Dismissed proposals never execute.
    func test_dismissed_neverExecutes() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let spies = ProposalType.allCases.map { SpyHandler($0) }
        let eng = engine(ctx, clock: clock, handlers: spies)

        let proposal = PX.pending(.rememberFact, payload: ["k": "v"])
        try eng.enqueue(proposal)
        try eng.dismiss(proposal)

        XCTAssertEqual(proposal.status, .dismissed)
        XCTAssertTrue(spies.allSatisfy { $0.executeCount == 0 }, "no handler runs on dismiss")

        // And a dismissed proposal can no longer be approved.
        await XCTAssertThrowsErrorAsync(try await eng.approve(proposal)) { error in
            XCTAssertEqual(error as? ProposalError, .notPending(.dismissed))
        }
        XCTAssertTrue(spies.allSatisfy { $0.executeCount == 0 })
    }

    /// Snoozed proposals never execute.
    func test_snoozed_neverExecutes() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let spies = ProposalType.allCases.map { SpyHandler($0) }
        let eng = engine(ctx, clock: clock, handlers: spies)

        let proposal = PX.pending(.createAgentCalendarEvent, payload: ["k": "v"])
        try eng.enqueue(proposal)
        try eng.snooze(proposal, until: PX.now + PX.day)

        XCTAssertEqual(proposal.status, .snoozed)
        XCTAssertTrue(spies.allSatisfy { $0.executeCount == 0 })
        // Snoozed is not pending → not in the Inbox, and cannot be approved.
        XCTAssertTrue(try eng.pendingProposals().isEmpty)
        await XCTAssertThrowsErrorAsync(try await eng.approve(proposal)) { error in
            XCTAssertEqual(error as? ProposalError, .notPending(.snoozed))
        }
        XCTAssertTrue(spies.allSatisfy { $0.executeCount == 0 })
    }

    /// Expired proposals are DROPPED, never executed — via sweep and via a stale approve attempt.
    func test_expired_neverExecutes() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let spies = ProposalType.allCases.map { SpyHandler($0) }
        let eng = engine(ctx, clock: clock, handlers: spies)

        // Sweep path.
        let a = PX.pending(.modifyGoalPlan, payload: ["k": "v"], expiresAt: PX.now + PX.hour)
        try eng.enqueue(a)
        clock.advance(by: 2 * PX.hour)
        let swept = try eng.expirePendingPastDue()
        XCTAssertEqual(swept, 1)
        XCTAssertEqual(a.status, .expired)
        XCTAssertTrue(spies.allSatisfy { $0.executeCount == 0 })

        // Stale-approve path: a still-"pending" proposal past expiry is expired and refused,
        // NOT executed.
        let b = PX.pending(.rememberFact, payload: ["k": "v"], expiresAt: PX.now + PX.hour)
        try eng.enqueue(b)   // clock already advanced; enqueue keeps it pending
        await XCTAssertThrowsErrorAsync(try await eng.approve(b)) { error in
            XCTAssertEqual(error as? ProposalError, .expired)
        }
        XCTAssertEqual(b.status, .expired)
        XCTAssertTrue(spies.allSatisfy { $0.executeCount == 0 }, "expired approve executes nothing")
    }

    /// A non-pending (already approved) proposal cannot be approved again.
    func test_nonPending_cannotBeApproved() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let spy = SpyHandler(.rememberFact)
        let eng = engine(ctx, clock: clock, handlers: [spy])

        let proposal = PX.pending(.rememberFact, payload: ["k": "v"])
        try eng.enqueue(proposal)
        _ = try await eng.approve(proposal)
        XCTAssertEqual(spy.executeCount, 1)

        await XCTAssertThrowsErrorAsync(try await eng.approve(proposal)) { error in
            XCTAssertEqual(error as? ProposalError, .notPending(.approved))
        }
        XCTAssertEqual(spy.executeCount, 1, "second approve does not run the handler again")
    }

    /// Snoozed proposals resurface to pending after their resurface time — then execute normally.
    func test_snoozed_resurfaces_thenExecutes() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let spy = SpyHandler(.snoozeOpenLoop)
        let eng = engine(ctx, clock: clock, handlers: [spy])

        let proposal = PX.pending(.snoozeOpenLoop, payload: ["k": "v"])
        try eng.enqueue(proposal)
        try eng.snooze(proposal, until: PX.now + PX.day)
        XCTAssertTrue(try eng.pendingProposals().isEmpty)

        clock.advance(by: PX.day + PX.hour)
        let resurfaced = try eng.resurfaceDueSnoozed()
        XCTAssertEqual(resurfaced, 1)
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertNil(proposal.expiresAt, "resurface clears the resurface time so it is not re-expired")
        XCTAssertEqual(try eng.pendingProposals().count, 1)

        _ = try await eng.approve(proposal)
        XCTAssertEqual(spy.executeCount, 1)
    }

    /// dismiss/snooze/expire on an already-terminal proposal throw (guarded transitions).
    func test_transitions_requirePending() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let eng = engine(ctx, clock: clock, handlers: [SpyHandler(.rememberFact)])

        let p = PX.pending(.rememberFact, payload: ["k": "v"])
        try eng.enqueue(p)
        try eng.dismiss(p)
        XCTAssertThrowsError(try eng.snooze(p, until: PX.now + PX.day))
        XCTAssertThrowsError(try eng.expire(p))
        XCTAssertThrowsError(try eng.dismiss(p))
    }
}

/// Async throwing-assert helper (XCTest lacks a built-in async variant). `@MainActor` so it
/// can take closures that touch main-actor-isolated engine/store state.
@MainActor
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error but none was thrown. \(message)", file: file, line: line)
    } catch {
        handler(error)
    }
}
