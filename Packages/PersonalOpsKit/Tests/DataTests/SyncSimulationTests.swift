import XCTest
import SwiftData
import Core
import Fixtures
@testable import Data

/// # Phase 7A — sync-simulation harness (two containers + manual record exchange)
///
/// We can't run real CloudKit host-side, but the *app-level* invariants that must hold under sync
/// are testable with two independent local containers and a manual record-exchange step that
/// models CloudKit's convergence: every record is identified by its stable `appID`, and importing
/// is idempotent (a record already present by `appID` is not re-imported). That mirrors how
/// `NSPersistentCloudKitContainer` mirrors each `CKRecord` into a peer store exactly once.
///
/// These tests prove three invariants that sync makes *more* likely to occur:
///   1. **Revision-conflict surfacing** — two devices correct the same fact independently; after
///      exchange, `resolve()` reports `.conflict` (never an arbitrary silent winner).
///   2. **Duplicate reconciliation / last-writer-wins** — `GmailMessageRecord` is cache data; two
///      devices scanning the same message produces duplicate rows that reconcile to one by
///      scan recency, harmlessly.
///   3. **Deletion vs. concurrent edit** — because memory is append-only (expire, not destroy), an
///      edit on one device is not lost when the base was "deleted" (expired) on the other.
///
/// What still needs an on-device iCloud build: that real `CKRecord` mirroring actually delivers
/// these records between two signed-in devices, and hard-delete (tombstone) propagation timing.
final class SyncSimulationTests: XCTestCase {

    // MARK: - 1. Revision-conflict surfacing under sync

    func test_concurrentCorrections_onTwoDevices_surfaceAsConflictAfterSync() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000_000))
        let (ctxA, storeA) = try Self.device(clock)
        let (ctxB, storeB) = try Self.device(clock)

        // Shared base fact (rev 1) originates on A and syncs to B (same appID on both).
        try storeA.insert(Preference(factKey: "preference:workout", key: "workout", value: "am"))
        SyncSim.mergePreferences(from: ctxA, into: ctxB)

        // Each device independently corrects the same fact — the classic concurrent-edit case.
        let baseA = try XCTUnwrap(try storeA.activeRevisions(Preference.self, factKey: "preference:workout").first)
        try storeA.correct(baseA, reason: "device A") { $0.value = "dawn" }

        let baseB = try XCTUnwrap(try storeB.activeRevisions(Preference.self, factKey: "preference:workout").first)
        try storeB.correct(baseB, reason: "device B") { $0.value = "evening" }

        // Sync in both directions.
        SyncSim.mergePreferences(from: ctxA, into: ctxB)
        SyncSim.mergePreferences(from: ctxB, into: ctxA)

        // Both devices now surface an explicit conflict — two active revisions, no silent winner.
        for store in [storeA, storeB] {
            let resolution = try store.resolve(Preference.self, factKey: "preference:workout")
            XCTAssertTrue(resolution.isConflict, "concurrent corrections must surface as a conflict")
            if case let .conflict(revs) = resolution {
                XCTAssertEqual(Set(revs.map { $0.value }), ["dawn", "evening"])
            }
        }
    }

    // MARK: - 2. Duplicate reconciliation / last-writer-wins (GmailMessageRecord)

    func test_duplicateGmailRecords_fromTwoDevices_reconcileToOne_byRecency() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000_000))
        let (ctxA, _) = try Self.device(clock)
        let (ctxB, _) = try Self.device(clock)

        // Both devices scan the same message independently (no shared prior → distinct appIDs).
        let early = Date(timeIntervalSince1970: 2_000)
        let late = Date(timeIntervalSince1970: 9_000)
        ctxA.insert(GmailMessageRecord(messageID: "m1", threadID: "t1", scanTimestamp: early, subject: "Old scan"))
        try ctxA.save()
        ctxB.insert(GmailMessageRecord(messageID: "m1", threadID: "t1", scanTimestamp: late, subject: "New scan"))
        try ctxB.save()

        // Sync both ways → each store now has two rows for messageID m1.
        SyncSim.mergeGmailRecords(from: ctxA, into: ctxB)
        SyncSim.mergeGmailRecords(from: ctxB, into: ctxA)
        XCTAssertEqual(try Self.gmailRows(ctxA, messageID: "m1").count, 2, "duplicate before reconcile")

        // Harmless: the "seen" invariant still holds even with duplicates present.
        XCTAssertFalse(try Self.gmailRows(ctxA, messageID: "m1").isEmpty)

        // App-level reconcile (last-writer-wins by scan recency) collapses to exactly one.
        SyncSim.reconcileGmailRecords(in: ctxA)
        let survivors = try Self.gmailRows(ctxA, messageID: "m1")
        XCTAssertEqual(survivors.count, 1, "LWW reconcile keeps exactly one record per messageID")
        XCTAssertEqual(survivors.first?.scanTimestamp, late, "the most recent scan wins")
    }

    // MARK: - 3. Deletion vs. concurrent edit (append-only ⇒ edit not lost)

    func test_deletedOnOneDevice_editedOnOther_editSurvives() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000_000))
        let (ctxA, storeA) = try Self.device(clock)
        let (ctxB, storeB) = try Self.device(clock)

        try storeA.insert(OpenLoop(factKey: "loop:recruiter", title: "Waiting on recruiter"))
        SyncSim.mergeOpenLoops(from: ctxA, into: ctxB)

        // Device A "deletes" the loop — in the append-only model that's an expire, not a destroy.
        let onA = try XCTUnwrap(try storeA.activeRevisions(OpenLoop.self, factKey: "loop:recruiter").first)
        try storeA.expire(onA)

        // Device B concurrently edits it (a correction → new active revision).
        let onB = try XCTUnwrap(try storeB.activeRevisions(OpenLoop.self, factKey: "loop:recruiter").first)
        try storeB.correct(onB, reason: "device B") { $0.title = "Recruiter replied — schedule call" }

        // Sync both ways.
        SyncSim.mergeOpenLoops(from: ctxA, into: ctxB)
        SyncSim.mergeOpenLoops(from: ctxB, into: ctxA)

        // The edit is NOT lost by the delete: A now resolves to B's active correction.
        let resolution = try storeA.resolve(OpenLoop.self, factKey: "loop:recruiter")
        XCTAssertEqual(resolution.value?.title, "Recruiter replied — schedule call",
                       "an edit on one device must survive a concurrent 'delete' (expire) on the other")
    }

    // MARK: - Helpers

    private static func device(_ clock: FakeClock) throws -> (ModelContext, MemoryStore) {
        let ctx = ModelContext(try DataStore.makeContainer(inMemory: true))
        return (ctx, MemoryStore(context: ctx, clock: clock))
    }

    private static func gmailRows(_ ctx: ModelContext, messageID: String) throws -> [GmailMessageRecord] {
        try ctx.fetch(FetchDescriptor<GmailMessageRecord>()).filter { $0.messageID == messageID }
    }
}
