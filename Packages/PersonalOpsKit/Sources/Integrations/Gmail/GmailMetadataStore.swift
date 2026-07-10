import Foundation

/// Persists the minimal Gmail metadata the app is allowed to keep (message ID, thread ID,
/// received date, scan timestamp, short snippet) — never full bodies (PRD Data Boundaries).
///
/// Abstracted behind a protocol so Phase 2 ships an in-memory implementation (sufficient for
/// the "stores metadata per message" acceptance test and the incremental-scan cursor) and
/// Phase 4B — which turns these into Proposals and needs durable dedupe across launches —
/// can swap in a SwiftData-backed store without changing the Gmail client.
public protocol GmailMetadataStore: Sendable {
    /// Upsert a batch of scanned messages, keyed by `messageID` (a re-scan of the same
    /// message replaces its record rather than duplicating it).
    func upsert(_ messages: [GmailMessageMetadata]) async
    /// All stored metadata.
    func all() async -> [GmailMessageMetadata]
    /// The most recent `receivedDate` seen (the incremental-scan cursor), or `nil` if empty.
    func latestReceivedDate() async -> Date?
}

/// In-memory `GmailMetadataStore` (Phase 2 default; test and first-run friendly).
public actor InMemoryGmailMetadataStore: GmailMetadataStore {
    private var byMessageID: [String: GmailMessageMetadata] = [:]

    public init(seed: [GmailMessageMetadata] = []) {
        for m in seed { byMessageID[m.messageID] = m }
    }

    public func upsert(_ messages: [GmailMessageMetadata]) async {
        for m in messages { byMessageID[m.messageID] = m }
    }

    public func all() async -> [GmailMessageMetadata] {
        byMessageID.values.sorted { $0.receivedDate > $1.receivedDate }
    }

    public func latestReceivedDate() async -> Date? {
        byMessageID.values.map(\.receivedDate).max()
    }
}
