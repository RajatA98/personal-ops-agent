import Foundation
import Core

/// Gmail message metadata. Per the data-boundary rule (PROJECT_PLAN Phase 2), we store
/// ids + dates + a minimal snippet — never unnecessary raw body content.
///
/// Phase 4B added `subject` and `sender` (both **header** metadata, never the body): the
/// deterministic signal extractor reads subject/snippet for meeting-ish patterns, and the
/// "mark as wrong" downranking keys on a sender-domain + subject-shape pattern. Both stay
/// inside the "ids + dates + minimal metadata, not raw body content" boundary.
public struct GmailMessageMetadata: Equatable, Sendable {
    public let messageID: String
    public let threadID: String
    public let receivedDate: Date
    public let scanTimestamp: Date
    public let snippet: String?
    /// `Subject` header (metadata) — optional; absent for messages fetched without it.
    public let subject: String?
    /// `From` header (metadata) — the raw sender, e.g. `"Jobs <no-reply@jobs.example.com>"`.
    public let sender: String?

    public init(messageID: String, threadID: String, receivedDate: Date,
                scanTimestamp: Date, snippet: String? = nil,
                subject: String? = nil, sender: String? = nil) {
        self.messageID = messageID
        self.threadID = threadID
        self.receivedDate = receivedDate
        self.scanTimestamp = scanTimestamp
        self.snippet = snippet
        self.subject = subject
        self.sender = sender
    }
}

/// Read-only Gmail access (`gmail.readonly`). Real implementation lands in Phase 2.
public protocol GmailAPI: Sendable {
    func listRecentMessages(query: String?, since: Date?) async throws -> [GmailMessageMetadata]
}
