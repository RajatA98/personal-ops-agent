import XCTest
import SwiftData
import Core
import Fixtures
@testable import Data

/// The seed data backing the app shell must exercise all three lifecycle behaviors so the
/// UI shows something real, and it must be idempotent (safe to call on every launch).
final class MemorySampleDataTests: XCTestCase {

    func test_seed_populatesAllModelTypes_andExercisesLifecycle() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let context = try TestContainer.context()
        try MemorySampleData.seed(context: context, clock: clock)
        let store = MemoryStore(context: context, clock: clock)

        // Corrected preference: revision chain of 2, active is the morning value.
        let prefHistory = try store.history(Preference.self, factKey: "preference:workout_time_of_day")
        XCTAssertEqual(prefHistory.count, 2)
        XCTAssertEqual(try store.resolve(Preference.self, factKey: "preference:workout_time_of_day").value?.value, "morning")

        // Expired open loop: in history, absent from default view.
        if case .none = try store.resolve(OpenLoop.self, factKey: "open_loop:contoso_recruiter") {} else {
            XCTFail("expired loop should not resolve")
        }
        XCTAssertEqual(try store.history(OpenLoop.self, factKey: "open_loop:contoso_recruiter").count, 1)

        // Conflict: two active decisions for acme_offer.
        XCTAssertTrue(try store.resolve(Decision.self, factKey: "decision:acme_offer").isConflict)

        // Structural + remaining models present.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Goal>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GoalTask>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Commitment>()).count, 1)
        // `Pattern` collides with a C `struct Pattern` (Quickdraw) in type position inside
        // test modules; infer the model type from an expression to name it unambiguously.
        XCTAssertEqual(try store.all(type(of: Pattern())).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DailyLog>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Proposal>()).count, 1)
    }

    func test_seedIfEmpty_isIdempotent() throws {
        let clock = FakeClock()
        let context = try TestContainer.context()
        XCTAssertTrue(try MemorySampleData.seedIfEmpty(context: context, clock: clock))
        let prefCountAfterFirst = try context.fetch(FetchDescriptor<Preference>()).count
        XCTAssertFalse(try MemorySampleData.seedIfEmpty(context: context, clock: clock), "second call is a no-op")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Preference>()).count, prefCountAfterFirst)
    }
}
