import XCTest
import SwiftData
import Core
@testable import Data

/// # Phase 7A — on-disk V1→V2 migration against existing local (pre-sync) data
///
/// Phase 4B added `GmailMessageRecord` as schema V2 via a single `.lightweight` stage and asked
/// 7A to prove the migration runs against a real on-disk V1 store (not just an in-memory one).
/// This is that test: it writes a genuine **V1** store to disk (V1 schema only — no
/// `GmailMessageRecord` exists yet), releases it, then reopens the same file through the shipping
/// `MemoryMigrationPlan` (V2) and asserts (a) the migration succeeds, (b) the pre-existing rows are
/// intact, and (c) the new V2-only model is now usable. This is also the "CloudKit migration test
/// against existing local data" the plan's acceptance criteria call for — the migration a device
/// runs the first time sync is switched on over an already-populated local store.
final class MigrationTests: XCTestCase {

    func test_v1StoreOnDisk_migratesToV2_dataIntact_andNewModelUsable() throws {
        let url = Self.tempStoreURL()
        defer { Self.removeStore(at: url) }

        // 1. Write a real V1 store on disk (V1 schema: no GmailMessageRecord).
        let goalAppID = try writeV1Store(at: url)

        // 2. Reopen the SAME file through the shipping V2 schema + migration plan.
        let migrated = try DataStore.makeContainer(url: url)
        let context = ModelContext(migrated)

        // 3a. Pre-existing V1 rows survived the lightweight migration.
        let prefs = try context.fetch(FetchDescriptor<Preference>())
        XCTAssertEqual(prefs.count, 1)
        XCTAssertEqual(prefs.first?.value, "morning")

        let goals = try context.fetch(FetchDescriptor<Goal>())
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals.first?.appID, goalAppID)
        XCTAssertEqual(goals.first?.title, "Ironman 70.3")
        // The relationship survived too.
        XCTAssertEqual(goals.first?.tasks?.count, 1)

        // 3b. The V2-only model (GmailMessageRecord) is registered and writable post-migration.
        context.insert(GmailMessageRecord(messageID: "m1", threadID: "t1"))
        XCTAssertNoThrow(try context.save())
        XCTAssertEqual(try context.fetch(FetchDescriptor<GmailMessageRecord>()).count, 1)
    }

    /// # Phase 7B — on-disk V2→V3 migration against existing local data
    ///
    /// Phase 7B adds `HealthSummaryRecord` as schema V3 via a single `.lightweight` stage (the
    /// synced health-summary path for macOS pacing). Same proof as the V1→V2 test, one version up:
    /// write a genuine **V2** store on disk (V2 schema — GmailMessageRecord exists, but no
    /// HealthSummaryRecord), release it, reopen through the shipping V3 plan, and assert the
    /// pre-existing rows survived AND the new V3-only model is usable. Because the full plan runs
    /// V1→V2→V3, this also confirms the two lightweight stages compose.
    func test_v2StoreOnDisk_migratesToV3_dataIntact_andNewModelUsable() throws {
        let url = Self.tempStoreURL()
        defer { Self.removeStore(at: url) }

        // 1. Write a real V2 store on disk (V2 schema: has GmailMessageRecord, no HealthSummaryRecord).
        let goalAppID = try writeV2Store(at: url)

        // 2. Reopen the SAME file through the shipping V3 schema + migration plan.
        let migrated = try DataStore.makeContainer(url: url)
        let context = ModelContext(migrated)

        // 3a. Pre-existing V2 rows survived the lightweight migration.
        let prefs = try context.fetch(FetchDescriptor<Preference>())
        XCTAssertEqual(prefs.count, 1)
        XCTAssertEqual(prefs.first?.value, "morning")

        let goals = try context.fetch(FetchDescriptor<Goal>())
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals.first?.appID, goalAppID)
        XCTAssertEqual(goals.first?.tasks?.count, 1)

        // The V2 model (GmailMessageRecord) is still present + usable after the V2→V3 stage.
        let records = try context.fetch(FetchDescriptor<GmailMessageRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.messageID, "m1")

        // 3b. The V3-only model (HealthSummaryRecord) is registered and writable post-migration.
        context.insert(HealthSummaryRecord(dayKey: "2026-07-10",
                                           date: Date(timeIntervalSince1970: 1_000_000),
                                           sleepHours: 6.9))
        XCTAssertNoThrow(try context.save())
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSummaryRecord>()).count, 1)
    }

    /// Writes a populated V2 store at `url` using ONLY the V2 schema (so the store's recorded
    /// version is genuinely 2). Returns the goal's appID for a post-migration identity check.
    private func writeV2Store(at url: URL) throws -> UUID {
        let v2Schema = Schema(versionedSchema: DataSchemaV2.self)
        let config = ModelConfiguration(schema: v2Schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: v2Schema,
                                           migrationPlan: nil,
                                           configurations: config)
        let context = ModelContext(container)

        let pref = Preference(factKey: "preference:workout_time", key: "workout_time", value: "morning")
        context.insert(pref)

        let goal = Goal(factKey: "goal:ironman", title: "Ironman 70.3", playbookKey: "training")
        goal.tasks = [GoalTask(title: "Long ride", flexibility: .fixed, conflictPolicy: .block)]
        context.insert(goal)

        context.insert(GmailMessageRecord(messageID: "m1", threadID: "t1"))

        try context.save()
        return goal.appID
    }

    /// Writes a populated V1 store at `url` using ONLY the V1 schema (so the store's recorded
    /// version is genuinely 1). Returns the goal's appID for a post-migration identity check. The
    /// container is local to this method so it is released before the caller reopens the file.
    private func writeV1Store(at url: URL) throws -> UUID {
        let v1Schema = Schema(versionedSchema: DataSchemaV1.self)
        let config = ModelConfiguration(schema: v1Schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: v1Schema,
                                           migrationPlan: nil,
                                           configurations: config)
        let context = ModelContext(container)

        let pref = Preference(factKey: "preference:workout_time", key: "workout_time", value: "morning")
        context.insert(pref)

        let goal = Goal(factKey: "goal:ironman", title: "Ironman 70.3", playbookKey: "training")
        goal.tasks = [GoalTask(title: "Long ride", flexibility: .fixed, conflictPolicy: .block)]
        context.insert(goal)

        try context.save()
        return goal.appID
    }

    static func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pok-migration-\(UUID().uuidString).store")
    }

    static func removeStore(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
