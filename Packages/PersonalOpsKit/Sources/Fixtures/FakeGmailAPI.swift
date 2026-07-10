import Foundation
import Core
import Integrations

/// Protocol-based fake for `GmailAPI` with minimal seed metadata (ids + dates, no raw
/// bodies — matching the Phase 2 data boundary). Real read-only implementation lands in
/// Phase 2; Phase 4B derives Proposals from this shape.
public final class FakeGmailAPI: GmailAPI, @unchecked Sendable {

    private let messages: [GmailMessageMetadata]

    public init(messages: [GmailMessageMetadata] = []) {
        self.messages = messages
    }

    public func listRecentMessages(query: String?, since: Date?) async throws -> [GmailMessageMetadata] {
        guard let since else { return messages }
        return messages.filter { $0.receivedDate >= since }
    }

    public static func seeded(referenceDate: Date = Date(timeIntervalSince1970: 1_000_000)) -> FakeGmailAPI {
        let scan = referenceDate
        return FakeGmailAPI(messages: [
            GmailMessageMetadata(
                messageID: "msg-1001", threadID: "thread-500",
                receivedDate: referenceDate.addingTimeInterval(-7200),
                scanTimestamp: scan,
                snippet: "Interview confirmed for Thursday at 3pm",
                subject: "Interview confirmed for Thursday 3pm",
                sender: "Recruiting <no-reply@jobs.example.com>"),
            GmailMessageMetadata(
                messageID: "msg-1002", threadID: "thread-501",
                receivedDate: referenceDate.addingTimeInterval(-3600),
                scanTimestamp: scan,
                snippet: "Race registration receipt",
                subject: "Your race registration receipt",
                sender: "Registration <receipts@raceday.example.com>")
        ])
    }
}
