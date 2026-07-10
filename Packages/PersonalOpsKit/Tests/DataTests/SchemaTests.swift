import XCTest
import SwiftData
import Core
@testable import Data

/// Proves the model container initializes cleanly with the full intended schema, and that
/// the schema satisfies the CloudKit constraints that ARE checkable host-side. (What can
/// only be verified on-device with an iCloud-entitled build is called out in the doc for
/// `CloudKitCompatibilityTests` and deferred to Phase 7A.)
final class SchemaTests: XCTestCase {

    private let expectedEntities: Set<String> = [
        "DailyLog", "Commitment", "Goal", "GoalTask", "GoalProgress",
        "Decision", "Preference", "OpenLoop", "Pattern", "Proposal"
    ]

    func test_container_initializesCleanly_withFullSchema() throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let names = Set(container.schema.entities.map(\.name))
        XCTAssertEqual(names, expectedEntities, "every Phase 1 model must be in the shipped schema")
    }

    func test_schemaVersion_isV1() throws {
        XCTAssertEqual(DataModule.schemaVersion, 1)
        XCTAssertEqual(DataSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(MemoryMigrationPlan.schemas.count, 1)
        XCTAssertTrue(MemoryMigrationPlan.stages.isEmpty, "V1 is the baseline: no migration stages yet")
    }

    func test_containerCanReadAndWrite_everyModelType() throws {
        let context = try TestContainer.context()
        let store = MemoryStore(context: context, clock: SystemClock())

        // A round-trip insert per type proves each @Model is registered and persistable.
        try store.insert(DailyLog(factKey: "d", summary: "s"))
        try store.insert(Commitment(factKey: "c", title: "t"))
        try store.insert(Decision(factKey: "de", topic: "x", choice: "y"))
        try store.insert(Preference(factKey: "p", key: "k", value: "v"))
        try store.insert(OpenLoop(factKey: "o", title: "t"))
        try store.insert(Pattern(factKey: "pa", name: "n"))
        try store.insert(GoalProgress(factKey: "gp", metricKey: "m", value: 1))
        try store.insert(Proposal(factKey: "pr", type: .rememberFact))

        let goal = Goal(factKey: "g", title: "G", playbookKey: "training")
        goal.tasks = [GoalTask(title: "task")]
        goal.progress = [GoalProgress(factKey: "gp2", metricKey: "m2", value: 2)]
        context.insert(goal)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Goal>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GoalTask>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Preference>()).count, 1)
    }

    func test_goalRelationships_roundTripWithInverse() throws {
        let context = try TestContainer.context()
        let goal = Goal(factKey: "g", title: "Ironman", playbookKey: "training")
        let task = GoalTask(title: "long ride", flexibility: .fixed, conflictPolicy: .block)
        goal.tasks = [task]
        context.insert(goal)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<GoalTask>()).first)
        XCTAssertEqual(fetched.goal?.appID, goal.appID, "inverse relationship resolves both ways")
        XCTAssertEqual(fetched.flexibility, .fixed)
        XCTAssertEqual(fetched.conflictPolicy, .block)
    }
}
