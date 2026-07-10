import XCTest
import SwiftData
import Core
import Fixtures
@testable import Data

/// The Phase 1 memory-lifecycle acceptance criteria, one test per criterion.
final class MemoryLifecycleTests: XCTestCase {

    private func makeStore(_ clock: FakeClock) throws -> (MemoryStore, ModelContext) {
        let context = try TestContainer.context()
        return (MemoryStore(context: context, clock: clock), context)
    }

    // MARK: Acceptance #1 — correction creates n+1, keeps n superseded, default returns n+1

    func test_correction_createsRevisionNPlusOne_supersedesN_defaultReturnsNPlusOne() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000_000))
        let (store, _) = try makeStore(clock)

        let pref = Preference(source: .user, key: "workout_time", value: "evening")
        pref.factKey = "preference:workout_time"
        try store.insert(pref)
        XCTAssertEqual(pref.revision, 1)

        clock.advance(by: 3600)
        let corrected = try store.correct(pref, reason: "switched to mornings") { $0.value = "morning" }

        // New revision is n+1 with the corrected value and the reason recorded.
        XCTAssertEqual(corrected.revision, 2)
        XCTAssertEqual(corrected.value, "morning")
        XCTAssertEqual(corrected.correctionReason, "switched to mornings")
        XCTAssertNil(corrected.supersededAt)
        XCTAssertNotEqual(corrected.appID, pref.appID, "correction mints a fresh app-level ID")

        // Revision n is superseded, NOT deleted, and its prior value/source are preserved.
        XCTAssertNotNil(pref.supersededAt)
        XCTAssertEqual(pref.supersededByAppID, corrected.appID)
        XCTAssertEqual(pref.value, "evening", "prior value is preserved, not overwritten")
        XCTAssertEqual(pref.source, .user)

        // Both rows still exist (append-only).
        XCTAssertEqual(try store.history(Preference.self, factKey: "preference:workout_time").count, 2)

        // Default query returns only n+1.
        let resolution = try store.resolve(Preference.self, factKey: "preference:workout_time")
        guard case let .resolved(active) = resolution else {
            return XCTFail("expected a single resolved revision, got \(resolution)")
        }
        XCTAssertEqual(active.appID, corrected.appID)
        XCTAssertEqual(active.revision, 2)
    }

    // MARK: Acceptance #2 — expired excluded from default query, present in history

    func test_expiredEntity_excludedFromDefault_presentInHistory() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 2_000_000))
        let (store, _) = try makeStore(clock)

        let loop = OpenLoop(source: .gmail, title: "await recruiter")
        loop.factKey = "open_loop:recruiter"
        loop.expiresAt = clock.now.addingTimeInterval(60) // expires in 1 minute
        try store.insert(loop)

        // Before expiry: active.
        XCTAssertFalse(loop.isExpired(asOf: clock.now))
        if case .resolved = try store.resolve(OpenLoop.self, factKey: "open_loop:recruiter") {} else {
            XCTFail("should be resolved before expiry")
        }

        // After expiry: excluded from the default query...
        clock.advance(by: 120)
        XCTAssertTrue(loop.isExpired(asOf: clock.now))
        if case .none = try store.resolve(OpenLoop.self, factKey: "open_loop:recruiter") {} else {
            XCTFail("expired entity must be excluded from the default query")
        }
        XCTAssertTrue(try store.activeRevisions(OpenLoop.self, factKey: "open_loop:recruiter").isEmpty)

        // ...but still present in history.
        let history = try store.history(OpenLoop.self, factKey: "open_loop:recruiter")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.appID, loop.appID)
    }

    // MARK: Acceptance #3 — two active conflicting memories return an explicit conflict

    func test_twoActiveConflictingMemories_returnExplicitConflict_notArbitraryWinner() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 3_000_000))
        let (store, _) = try makeStore(clock)

        let a = Decision(source: .user, topic: "acme_offer", choice: "accept")
        a.factKey = "decision:acme_offer"
        let b = Decision(source: .gmail, topic: "acme_offer", choice: "decline")
        b.factKey = "decision:acme_offer"
        try store.insert(a)
        try store.insert(b)

        let resolution = try store.resolve(Decision.self, factKey: "decision:acme_offer")
        guard case let .conflict(conflicting) = resolution else {
            return XCTFail("expected an explicit conflict, got \(resolution)")
        }
        XCTAssertTrue(resolution.isConflict)
        XCTAssertNil(resolution.value, "a conflict must not resolve to an arbitrary single value")
        XCTAssertEqual(Set(conflicting.map(\.appID)), Set([a.appID, b.appID]))

        // Correcting one side does NOT collapse the conflict — a correction mints a fresh
        // active revision, so two independent active claims still exist. The engine keeps
        // reporting the conflict rather than hiding the newly-corrected value as "the truth".
        try store.correct(a, reason: "revised rationale") { $0.rationale = "on reflection" }
        XCTAssertTrue(
            try store.resolve(Decision.self, factKey: "decision:acme_offer").isConflict,
            "correcting one claim leaves the other still-conflicting claim active"
        )
        XCTAssertEqual(try store.activeRevisions(Decision.self, factKey: "decision:acme_offer").count, 2)

        // The honest way to collapse a conflict is to retire one claim down to a single
        // active revision — e.g. expire b. Then the remaining claim resolves cleanly.
        try store.expire(b)
        let resolved = try store.resolve(Decision.self, factKey: "decision:acme_offer")
        guard case let .resolved(winner) = resolved else {
            return XCTFail("with one claim expired, the other resolves cleanly, got \(resolved)")
        }
        XCTAssertEqual(winner.topic, "acme_offer")
        XCTAssertEqual(winner.choice, "accept", "the surviving claim is a's chain, not an arbitrary pick")
    }

    // MARK: Supporting — makeRevisionCopy produces an independent, un-superseded duplicate

    func test_makeRevisionCopy_isIndependentAndClean() throws {
        let clock = FakeClock()
        let (store, _) = try makeStore(clock)
        let original = Commitment(source: .user, title: "call dentist", isDone: false)
        original.factKey = "commitment:dentist"
        try store.insert(original)

        let copy = original.makeRevisionCopy()
        XCTAssertNotEqual(copy.appID, original.appID)
        XCTAssertEqual(copy.factKey, original.factKey)
        XCTAssertEqual(copy.title, original.title)
        XCTAssertNil(copy.supersededAt)
        XCTAssertNil(copy.supersededByAppID)
    }
}
