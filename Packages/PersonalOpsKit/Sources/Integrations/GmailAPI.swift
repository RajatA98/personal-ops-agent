import Foundation
import Core

/// Gmail message metadata. Per the data-boundary rule (PROJECT_PLAN Phase 2), we store
/// ids + dates + a minimal snippet — never unnecessary raw body content.
public struct GmailMessageMetadata: Equatable, Sendable {
    public let messageID: String
    public let threadID: String
    public let receivedDate: Date
    public let scanTimestamp: Date
    public let snippet: String?

    public init(messageID: String, threadID: String, receivedDate: Date,
                scanTimestamp: Date, snippet: String? = nil) {
        self.messageID = messageID
        self.threadID = threadID
        self.receivedDate = receivedDate
        self.scanTimestamp = scanTimestamp
        self.snippet = snippet
    }
}

/// Read-only Gmail access (`gmail.readonly`). Real implementation lands in Phase 2.
public protocol GmailAPI: Sendable {
    func listRecentMessages(query: String?, since: Date?) async throws -> [GmailMessageMetadata]
}
