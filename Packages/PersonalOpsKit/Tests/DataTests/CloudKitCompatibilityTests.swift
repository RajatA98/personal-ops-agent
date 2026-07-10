import XCTest
import SwiftData
import Core
@testable import Data

/// Host-side CloudKit-compatibility checks.
///
/// CloudKit + SwiftData imposes three schema constraints. Two are reflectable host-side
/// and asserted here; the third is enforced by construction and re-checked below:
///   1. **No unique constraints** — asserted directly against `Schema.Entity`.
///   2. **All attributes optional or defaulted** — every stored property in this phase is
///      either optional or declared with an inline default; spot-checked here by proving
///      a default-constructed instance of every model persists with no supplied values.
///   3. **All relationships optional with a defined inverse** — the relationship-bearing
///      models (`Goal` ⇄ `GoalTask`, `Goal` ⇄ `GoalProgress`) are declared `[…]?` / `…?`
///      with `@Relationship(inverse:)`; the inverse round-trip is proven in `SchemaTests`.
///
/// What can only be verified on-device (Phase 7A): actually initializing a container with
/// `cloudKitDatabase: .automatic` under an iCloud-entitled build, which is when SwiftData
/// runs its full CloudKit validation and CloudKit provisions the record types. That is
/// out of scope for host-side `swift test` and is called out in `DataSchema.swift`.
final class CloudKitCompatibilityTests: XCTestCase {

    func test_noEntityDeclaresUniquenessConstraints() throws {
        let container = try DataStore.makeContainer(inMemory: true)
        for entity in container.schema.entities {
            XCTAssertTrue(
                entity.uniquenessConstraints.isEmpty,
                "\(entity.name) declares a uniqueness constraint — CloudKit forbids these. " +
                "Uniqueness for appID is a write-time convention, not a store constraint."
            )
        }
    }

    func test_everyModel_persistsWithAllDefaultValues() throws {
        // If any non-optional attribute lacked a default, default-construction + save would
        // trap or the schema would be CloudKit-incompatible. Proving a bare instance of each
        // model saves demonstrates the "optional-or-defaulted" rule holds in practice.
        let context = try TestContainer.context()
        context.insert(DailyLog())
        context.insert(Commitment())
        context.insert(Goal())
        context.insert(GoalTask())
        context.insert(GoalProgress())
        context.insert(Decision())
        context.insert(Preference())
        context.insert(OpenLoop())
        context.insert(Pattern())
        context.insert(Proposal())
        XCTAssertNoThrow(try context.save())
    }

    func test_appID_isStable_andDistinctFromPersistentIdentity() throws {
        // The appID convention: a stable app-level ID separate from SwiftData object identity.
        let context = try TestContainer.context()
        let pref = Preference(factKey: "p", key: "k", value: "v")
        let mintedID = pref.appID
        context.insert(pref)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Preference>()).first)
        XCTAssertEqual(fetched.appID, mintedID, "appID survives persistence unchanged")
        // Two fresh instances get distinct appIDs (no accidental sharing / no unique clash).
        XCTAssertNotEqual(Preference().appID, Preference().appID)
    }

    func test_enumBackedFields_storeAndReadAsRawStrings() throws {
        // Enums are stored as raw strings (CloudKit-friendly, predicate-friendly) with typed
        // accessors — verify the round-trip for each enum-backed field.
        let context = try TestContainer.context()
        let proposal = Proposal(type: .createAgentCalendarEvent, status: .snoozed)
        let task = GoalTask(flexibility: .optional, conflictPolicy: .allow)
        let goal = Goal(status: .paused)
        context.insert(proposal); context.insert(task); context.insert(goal)
        try context.save()

        XCTAssertEqual(proposal.typeRaw, "create_agent_calendar_event")
        XCTAssertEqual(proposal.status, .snoozed)
        XCTAssertEqual(task.flexibility, .optional)
        XCTAssertEqual(task.conflictPolicy, .allow)
        XCTAssertEqual(goal.status, .paused)
    }
}
