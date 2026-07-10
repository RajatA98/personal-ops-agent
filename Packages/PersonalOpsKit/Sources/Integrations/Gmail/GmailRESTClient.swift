import Foundation
import Core

/// Direct Gmail REST v1 client, read-only (`gmail.readonly`, LOCKED_DECISIONS #4). Lists /
/// searches messages, then fetches each with `format=metadata` (headers only — never the
/// body) and stores exactly the data-boundary set: message ID, thread ID, received date,
/// scan timestamp, and Gmail's short snippet. No send capability exists anywhere (Safety
/// Rule #4).
public actor GmailRESTClient: GmailAPI {

    private let tokenProvider: AccessTokenProviding
    private let transport: HTTPTransport
    private let metadataStore: GmailMetadataStore
    private let status: IntegrationStatusReporting?
    private let clock: any Clock
    private let retryPolicy: RetryPolicy
    private let baseURL: URL

    public init(tokenProvider: AccessTokenProviding,
                transport: HTTPTransport,
                metadataStore: GmailMetadataStore,
                status: IntegrationStatusReporting? = nil,
                clock: any Clock = SystemClock(),
                retryPolicy: RetryPolicy = .standard,
                baseURL: URL = URL(string: "https://gmail.googleapis.com")!) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.metadataStore = metadataStore
        self.status = status
        self.clock = clock
        self.retryPolicy = retryPolicy
        self.baseURL = baseURL
    }

    /// List recent messages matching `query`, newer than `since`, and store their metadata.
    public func listRecentMessages(query: String?, since: Date?) async throws -> [GmailMessageMetadata] {
        // 1. List message IDs (users.messages.list).
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/gmail/v1/users/me/messages"),
            resolvingAgainstBaseURL: false)!
        var q = query ?? ""
        if let since {
            // Gmail's `after:` takes a unix timestamp (seconds).
            let epoch = Int(since.timeIntervalSince1970)
            q = q.isEmpty ? "after:\(epoch)" : "\(q) after:\(epoch)"
        }
        var items = [URLQueryItem(name: "maxResults", value: "50")]
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        components.queryItems = items

        let listData = try await get(components.url!)
        let list = try decode(MessageListResponse.self, from: listData)
        let refs = list.messages ?? []

        // 2. Fetch each message's metadata (format=metadata → headers only, no body).
        var results: [GmailMessageMetadata] = []
        let scannedAt = clock.now
        for ref in refs {
            var msgComponents = URLComponents(
                url: baseURL.appendingPathComponent("/gmail/v1/users/me/messages/\(encode(ref.id))"),
                resolvingAgainstBaseURL: false)!
            // Header-only fetch (never the body). Subject/From are metadata used by Phase 4B's
            // deterministic signal extraction and its downranking pattern — still no body content.
            msgComponents.queryItems = [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "Date"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "From")
            ]
            let msgData = try await get(msgComponents.url!)
            let msg = try decode(MessageResource.self, from: msgData)
            results.append(GmailMessageMetadata(
                messageID: msg.id,
                threadID: msg.threadId,
                receivedDate: msg.receivedDate(),
                scanTimestamp: scannedAt,
                snippet: msg.snippet,
                subject: msg.header("Subject"),
                sender: msg.header("From")))
        }

        await metadataStore.upsert(results)
        await status?.reportSynced(.gmail, at: scannedAt, threshold: 30 * 60)
        return results
    }

    // MARK: - HTTP plumbing

    private func get(_ url: URL) async throws -> Data {
        try await withRetry(policy: retryPolicy) {
            let token = try await self.tokenProvider.validAccessToken()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await self.transport.send(request)
            if let error = HTTPErrorMapper.error(for: response.statusCode, source: .gmail, body: data) {
                throw error
            }
            return data
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AppError.network(.malformedResponse) }
    }

    private func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }
}

// MARK: - Wire DTOs (decode-only)

private struct MessageListResponse: Decodable {
    let messages: [MessageRef]?
}
private struct MessageRef: Decodable {
    let id: String
    let threadId: String?
}
private struct MessageResource: Decodable {
    let id: String
    let threadId: String
    let snippet: String?
    /// Milliseconds since epoch, as a string per the Gmail API.
    let internalDate: String?
    let payload: Payload?

    struct Payload: Decodable { let headers: [Header]? }
    struct Header: Decodable { let name: String; let value: String }

    /// Case-insensitive header lookup (Gmail returns canonical casing, but be defensive).
    func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    /// Prefer `internalDate` (authoritative receive time); fall back to the `Date` header.
    func receivedDate() -> Date {
        if let internalDate, let ms = Double(internalDate) {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let dateHeader = payload?.headers?.first(where: { $0.name.lowercased() == "date" })?.value {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let d = formatter.date(from: dateHeader) { return d }
        }
        return Date(timeIntervalSince1970: 0)
    }
}
