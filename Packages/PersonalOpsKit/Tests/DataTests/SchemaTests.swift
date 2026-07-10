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
        "Decision", "Preference", "OpenLoop", "Pattern", "Proposal",
        // Phase 4B: the durable Gmail scan ledger (V2, additive).
        "GmailMessageRecord",
        // Phase 7B: the syncable health summary for the macOS pacing path (V3, additive).
        "HealthSummaryRecord"
    ]

    func test_container_initializesCleanly_withFullSchema() throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let names = Set(container.schema.entities.map(\.name))
        XCTAssertEqual(names, expectedEntities, "every shipped model must be in the schema")
    }

    func test_schemaVersion_isV3() throws {
        XCTAssertEqual(DataModule.schemaVersion, 3)
        XCTAssertEqual(DataSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(DataSchemaV2.versionIdentifier, Schema.Version(2, 0, 0))
        XCTAssertEqual(DataSchemaV3.versionIdentifier, Schema.Version(3, 0, 0))
        // V1 + V2 + V3 registered; two additive lightweight stages bridge them.
        XCTAssertEqual(MemoryMigrationPlan.schemas.count, 3)
        XCTAssertEqual(MemoryMigrationPlan.stages.count, 2, "additive V1→V2 and V2→V3 stages")
        // Each version's only delta from its predecessor is one added model.
        let v1 = Set(DataSchemaV1.models.map { String(describing: $0) })
        let v2 = Set(DataSchemaV2.models.map { String(describing: $0) })
        let v3 = Set(DataSchemaV3.models.map { String(describing: $0) })
        XCTAssertEqual(v2.subtracting(v1), ["GmailMessageRecord"])
        XCTAssertEqual(v3.subtracting(v2), ["HealthSummaryRecord"])
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
