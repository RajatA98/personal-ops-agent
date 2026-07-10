import XCTest
import Foundation
import SwiftData
import Core
import Integrations
import Data
@testable import Signals

/// The durable Gmail scan ledger must survive a store roundtrip (relaunch), not just live in an
/// actor's in-memory state.
final class SwiftDataGmailMetadataStoreTests: XCTestCase {

    private func makeDiskContainer(at url: URL) throws -> ModelContainer {
        let config = ModelConfiguration(schema: DataStore.schema, url: url)
        return try ModelContainer(for: DataStore.schema,
                                  migrationPlan: MemoryMigrationPlan.self,
                                  configurations: config)
    }

    func test_upsertSurvivesStoreRoundtrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gmail.store")
        defer { try? FileManager.default.removeItem(at: dir) }

        let msg = GmailMessageMetadata(
            messageID: "m1", threadID: "t1",
            receivedDate: Date(timeIntervalSince1970: 1000),
            scanTimestamp: Date(timeIntervalSince1970: 2000),
            snippet: "hi", subject: "Subject", sender: "a@b.com")

        // Session 1: write, then drop the container.
        do {
            let container = try makeDiskContainer(at: url)
            let store = SwiftDataGmailMetadataStore(modelContainer: container)
            await store.upsert([msg])
            // Re-upsert the same messageID must NOT duplicate (write-time dedupe convention).
            await store.upsert([msg])
            let all = await store.all()
            XCTAssertEqual(all.count, 1)
        }

        // Session 2 (simulated relaunch): a fresh container over the same on-disk store.
        let container2 = try makeDiskContainer(at: url)
        let store2 = SwiftDataGmailMetadataStore(modelContainer: container2)
        let reloaded = await store2.all()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.messageID, "m1")
        XCTAssertEqual(reloaded.first?.subject, "Subject")
        XCTAssertEqual(reloaded.first?.sender, "a@b.com")
        let latest = await store2.latestReceivedDate()
        XCTAssertEqual(latest, Date(timeIntervalSince1970: 1000))
    }
}
