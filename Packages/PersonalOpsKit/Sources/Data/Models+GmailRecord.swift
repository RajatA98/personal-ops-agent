import Foundation
import SwiftData
import Core

/// # GmailMessageRecord — the durable Gmail scan ledger (Phase 4B)
///
/// A persisted record of a scanned Gmail message. Phase 2 stored this in an
/// `InMemoryGmailMetadataStore` (lost on relaunch); Phase 4B needs the "seen" set and the
/// incremental-scan cursor to **survive app relaunch** so a re-scan after the app is quit does
/// not re-propose everything. This is the SwiftData backing for the `GmailMetadataStore`
/// protocol (the conforming actor lives in `Signals`, which can see both this model and the
/// Integrations protocol; keeping the model here means it joins the versioned schema).
///
/// This is **operational metadata, not a corrigible memory fact** — it is *not* a
/// `MemoryEntity` (there is nothing to "correct" or revise about "this message was scanned").
/// It is a plain `@Model` that still follows the Phase 1 CloudKit-compatible conventions:
///   • a stable `appID` (the CloudKit-safe app-level identity convention),
///   • **no unique constraints** (uniqueness by `messageID` is a write-time upsert convention,
///     exactly like `appID` uniqueness elsewhere), and
///   • every attribute optional-or-defaulted.
///
/// ## Data boundary (PRD Data Boundaries)
/// Stores only headers + Gmail's own short snippet — **never the message body**. Phase 4B added
/// `subject`/`sender` (both header metadata, not body) because deterministic classification and
/// the "sender-domain + subject-shape" downranking pattern need them; they remain within the
/// "ids + dates + minimal metadata, not raw body content" boundary.
@Model
public final class GmailMessageRecord: AppEntity {
    public var appID: UUID = UUID()
    public var messageID: String = ""
    public var threadID: String = ""
    public var receivedDate: Date = Date(timeIntervalSince1970: 0)
    public var scanTimestamp: Date = Date(timeIntervalSince1970: 0)
    public var snippet: String?
    /// `Subject` header (metadata, never body). Optional — older records / plain lists omit it.
    public var subject: String?
    /// `From` header (metadata, never body) — the sender-domain half of the downrank pattern.
    public var sender: String?

    public init(appID: UUID = UUID(),
                messageID: String = "",
                threadID: String = "",
                receivedDate: Date = Date(timeIntervalSince1970: 0),
                scanTimestamp: Date = Date(timeIntervalSince1970: 0),
                snippet: String? = nil,
                subject: String? = nil,
                sender: String? = nil) {
        self.appID = appID
        self.messageID = messageID
        self.threadID = threadID
        self.receivedDate = receivedDate
        self.scanTimestamp = scanTimestamp
        self.snippet = snippet
        self.subject = subject
        self.sender = sender
    }
}
