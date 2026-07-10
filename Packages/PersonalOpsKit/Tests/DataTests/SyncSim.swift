import Foundation
import SwiftData
@testable import Data

/// # SyncSim — a manual record-exchange harness that models CloudKit convergence
///
/// Real CloudKit sync mirrors each `CKRecord` into the peer store exactly once, keyed by a stable
/// record ID. We can't run that host-side, but we can model it: export the rows of a type from one
/// container and import into another, **deduping by the stable `appID`** so re-running the exchange
/// is idempotent (exactly CloudKit's convergence property). Each imported row is a faithful copy —
/// same `appID` and full audit state — so the app's own merge logic (`MemoryStore.resolve`) sees
/// the same thing it would see after a real sync.
///
/// Per-type copiers (rather than one reflective copier) keep the harness honest and readable: each
/// preserves exactly that model's value fields plus the shared identity/audit fields.
enum SyncSim {

    // MARK: - MemoryEntity types

    static func mergePreferences(from src: ModelContext, into dst: ModelContext) {
        merge(Preference.self, from: src, into: dst) { p in
            Preference(appID: p.appID, factKey: p.factKey, revision: p.revision, source: p.source,
                       confidence: p.confidence, createdAt: p.createdAt, updatedAt: p.updatedAt,
                       expiresAt: p.expiresAt, supersededAt: p.supersededAt,
                       supersededByAppID: p.supersededByAppID, correctionReason: p.correctionReason,
                       key: p.key, value: p.value)
        }
    }

    static func mergeOpenLoops(from src: ModelContext, into dst: ModelContext) {
        merge(OpenLoop.self, from: src, into: dst) { l in
            OpenLoop(appID: l.appID, factKey: l.factKey, revision: l.revision, source: l.source,
                     confidence: l.confidence, createdAt: l.createdAt, updatedAt: l.updatedAt,
                     expiresAt: l.expiresAt, supersededAt: l.supersededAt,
                     supersededByAppID: l.supersededByAppID, correctionReason: l.correctionReason,
                     title: l.title, detail: l.detail, isResolved: l.isResolved,
                     snoozedUntil: l.snoozedUntil)
        }
    }

    // MARK: - Cache (last-writer-wins) types

    static func mergeGmailRecords(from src: ModelContext, into dst: ModelContext) {
        merge(GmailMessageRecord.self, from: src, into: dst) { r in
            GmailMessageRecord(appID: r.appID, messageID: r.messageID, threadID: r.threadID,
                               receivedDate: r.receivedDate, scanTimestamp: r.scanTimestamp,
                               snippet: r.snippet, subject: r.subject, sender: r.sender)
        }
    }

    /// Reconcile duplicate `GmailMessageRecord`s (the sync artifact when two devices scan the same
    /// message before converging): keep exactly one row per `messageID` — the most recent scan
    /// (last-writer-wins, since a scan ledger is cache data with nothing to "correct") — and delete
    /// the rest. Idempotent.
    static func reconcileGmailRecords(in ctx: ModelContext) {
        let all = (try? ctx.fetch(FetchDescriptor<GmailMessageRecord>())) ?? []
        let byMessage = Dictionary(grouping: all, by: { $0.messageID })
        for (_, rows) in byMessage where rows.count > 1 {
            let sorted = rows.sorted { $0.scanTimestamp > $1.scanTimestamp }
            for loser in sorted.dropFirst() { ctx.delete(loser) }
        }
        try? ctx.save()
    }

    // MARK: - Generic exchange

    /// Copy every row of `type` from `src` into `dst` that `dst` does not already hold (by `appID`),
    /// then save. Modeling CloudKit's exactly-once, idempotent per-record convergence.
    private static func merge<T: PersistentModel & AppEntity>(
        _ type: T.Type,
        from src: ModelContext,
        into dst: ModelContext,
        copy: (T) -> T
    ) {
        let present = Set(((try? dst.fetch(FetchDescriptor<T>())) ?? []).map(\.appID))
        for row in (try? src.fetch(FetchDescriptor<T>())) ?? [] where !present.contains(row.appID) {
            dst.insert(copy(row))
        }
        try? dst.save()
    }
}
