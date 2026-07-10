import XCTest
import Core
@testable import Integrations
import Fixtures

private struct StubTokenProvider: AccessTokenProviding {
    func validAccessToken() async throws -> String { "acc" }
}

final class GmailRESTClientTests: XCTestCase {

    override func tearDown() { MockURLProtocol.reset(); super.tearDown() }

    // ACCEPTANCE: Gmail sync stores messageID, threadID, receivedDate, scanTimestamp per message.
    func test_sync_storesMetadataPerMessage() async throws {
        MockURLProtocol.handler = { r in
            let path = r.url.path
            if path.hasSuffix("/messages") {
                let body = #"{"messages":[{"id":"m1","threadId":"t1"},{"id":"m2","threadId":"t2"}]}"#
                return (.make(r.url, 200), Data(body.utf8))
            }
            // Each message fetch must be metadata-only (format=metadata), never full body.
            XCTAssertTrue(r.url.query?.contains("format=metadata") ?? false,
                          "Gmail fetch must be metadata-only (data-boundary rule)")
            let id = String(path.split(separator: "/").last!)
            // internalDate is ms since epoch as a string.
            let internalDate = id == "m1" ? "1700000000000" : "1700000100000"
            let body = """
            {"id":"\(id)","threadId":"\(id == "m1" ? "t1" : "t2")","snippet":"hi","internalDate":"\(internalDate)"}
            """
            return (.make(r.url, 200), Data(body.utf8))
        }

        let store = InMemoryGmailMetadataStore()
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let client = GmailRESTClient(
            tokenProvider: StubTokenProvider(),
            transport: MockURLProtocol.transport(),
            metadataStore: store,
            clock: clock,
            retryPolicy: .none)

        let results = try await client.listRecentMessages(query: nil, since: nil)

        XCTAssertEqual(results.count, 2)
        let m1 = try XCTUnwrap(results.first { $0.messageID == "m1" })
        XCTAssertEqual(m1.threadID, "t1")
        XCTAssertEqual(m1.receivedDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(m1.scanTimestamp, clock.now, "scan timestamp is stamped from the clock")

        // Persisted to the store (durability for Phase 4B dedupe).
        let stored = await store.all()
        XCTAssertEqual(Set(stored.map(\.messageID)), ["m1", "m2"])
        let latest = await store.latestReceivedDate()
        XCTAssertEqual(latest, Date(timeIntervalSince1970: 1_700_000_100))
    }

    func test_sync_reScan_dedupesByMessageID() async throws {
        MockURLProtocol.handler = { r in
            if r.url.path.hasSuffix("/messages") {
                return (.make(r.url, 200), Data(#"{"messages":[{"id":"m1","threadId":"t1"}]}"#.utf8))
            }
            return (.make(r.url, 200), Data(#"{"id":"m1","threadId":"t1","snippet":"x","internalDate":"1700000000000"}"#.utf8))
        }
        let store = InMemoryGmailMetadataStore()
        let client = GmailRESTClient(tokenProvider: StubTokenProvider(),
                                     transport: MockURLProtocol.transport(),
                                     metadataStore: store,
                                     clock: FakeClock(), retryPolicy: .none)
        _ = try await client.listRecentMessages(query: nil, since: nil)
        _ = try await client.listRecentMessages(query: nil, since: nil)
        let stored = await store.all()
        XCTAssertEqual(stored.count, 1, "re-scanning the same message does not duplicate it")
    }
}
