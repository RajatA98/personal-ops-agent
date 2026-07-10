import Foundation
import SwiftData
import Integrations
import Data

/// # SwiftDataGmailMetadataStore — the durable `GmailMetadataStore` (Phase 4B)
///
/// Replaces Phase 2's `InMemoryGmailMetadataStore` for production: the scanned-message ledger
/// and the incremental-scan cursor (`latestReceivedDate`) now **persist across app relaunch**,
/// so quitting and reopening the app doesn't re-pull-and-re-propose everything. It conforms to
/// the same `GmailMetadataStore` protocol the `GmailRESTClient` already depends on, so swapping
/// it in is pure dependency injection — the client is unchanged.
///
/// ## Why a `@ModelActor`
/// The protocol is `Sendable` (the Gmail client is an `actor` and holds the store across
/// `await`s), and a `ModelContext` may only be touched on its owning actor. `@ModelActor`
/// synthesizes exactly that: a `Sendable` actor that owns a private `ModelContext` bound to the
/// injected container. All queries/writes below run on the actor's executor.
///
/// ## Dedupe convention (CloudKit-safe: no unique constraint)
/// `upsert` finds an existing record by `messageID` and updates it in place, else inserts — the
/// same write-time uniqueness convention the rest of the schema uses (the model carries no
/// unique attribute, which CloudKit forbids). A re-scan of the same message replaces its record
/// rather than duplicating it.
@ModelActor
public actor SwiftDataGmailMetadataStore: GmailMetadataStore {

    public func upsert(_ messages: [GmailMessageMetadata]) async {
        for m in messages {
            let messageID = m.messageID
            let existing = try? modelContext.fetch(
                FetchDescriptor<GmailMessageRecord>(
                    predicate: #Predicate { $0.messageID == messageID }))
            if let record = existing?.first {
                record.threadID = m.threadID
                record.receivedDate = m.receivedDate
                record.scanTimestamp = m.scanTimestamp
                record.snippet = m.snippet
                record.subject = m.subject
                record.sender = m.sender
            } else {
                modelContext.insert(GmailMessageRecord(
                    messageID: m.messageID, threadID: m.threadID,
                    receivedDate: m.receivedDate, scanTimestamp: m.scanTimestamp,
                    snippet: m.snippet, subject: m.subject, sender: m.sender))
            }
        }
        try? modelContext.save()
    }

    public func all() async -> [GmailMessageMetadata] {
        let records = (try? modelContext.fetch(FetchDescriptor<GmailMessageRecord>())) ?? []
        return records
            .sorted { $0.receivedDate > $1.receivedDate }
            .map { GmailMessageMetadata(
                messageID: $0.messageID, threadID: $0.threadID,
                receivedDate: $0.receivedDate, scanTimestamp: $0.scanTimestamp,
                snippet: $0.snippet, subject: $0.subject, sender: $0.sender) }
    }

    public func latestReceivedDate() async -> Date? {
        let records = (try? modelContext.fetch(FetchDescriptor<GmailMessageRecord>())) ?? []
        return records.map(\.receivedDate).max()
    }

    /// All stored records for a thread (used by the scan coordinator to recompute the downrank
    /// `sourcePattern` at "mark as wrong" time from durably-stored subject/sender).
    public func records(forThreadID threadID: String) async -> [GmailMessageMetadata] {
        let all = await all()
        return all.filter { $0.threadID == threadID }
    }
}
