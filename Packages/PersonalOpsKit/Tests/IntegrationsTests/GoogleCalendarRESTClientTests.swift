import XCTest
import Core
@testable import Integrations
import Fixtures

/// A minimal in-handler fake of the Google Calendar server: tracks created event IDs so the
/// idempotency test can prove a retried create yields exactly one event.
private final class FakeCalendarServer: @unchecked Sendable {
    var calendars: [(id: String, summary: String)] = [("primary", "My Calendar")]
    var createdEventIDs: Set<String> = []
    var events: [String: [String: Any]] = [:]

    func respond(_ r: MockURLProtocol.Recorded) throws -> (HTTPURLResponse, Data) {
        let path = r.url.path
        // calendarList
        if path.hasSuffix("/users/me/calendarList"), r.method == "GET" {
            let items = calendars.map { ["id": $0.id, "summary": $0.summary] }
            return (.make(r.url, 200), try json(["items": items]))
        }
        // create calendar
        if path.hasSuffix("/calendar/v3/calendars"), r.method == "POST" {
            let summary = (r.json?["summary"] as? String) ?? "Personal Ops Agent"
            let id = "agent-cal-id"
            calendars.append((id, summary))
            return (.make(r.url, 200), try json(["id": id, "summary": summary]))
        }
        // event create
        if path.hasSuffix("/events"), r.method == "POST" {
            guard let id = r.json?["id"] as? String else { return (.make(r.url, 400), Data()) }
            if createdEventIDs.contains(id) {
                // Duplicate caller-supplied ID ⇒ Google returns 409.
                return (.make(r.url, 409), try json(["error": ["errors": [["reason": "duplicate"]]]]))
            }
            createdEventIDs.insert(id)
            let body: [String: Any] = ["id": id, "summary": r.json?["summary"] ?? "",
                                       "start": ["dateTime": "2026-01-01T10:00:00Z"],
                                       "end": ["dateTime": "2026-01-01T11:00:00Z"]]
            events[id] = body
            return (.make(r.url, 200), try json(body))
        }
        // event get
        if path.contains("/events/"), r.method == "GET" {
            let id = String(path.split(separator: "/").last!)
            if let body = events[id] { return (.make(r.url, 200), try json(body)) }
            return (.make(r.url, 404), Data())
        }
        // events list
        if path.hasSuffix("/events"), r.method == "GET" {
            let items: [[String: Any]] = [[
                "id": "real-evt-1", "summary": "Standup",
                "start": ["dateTime": "2026-01-01T09:00:00Z"],
                "end": ["dateTime": "2026-01-01T09:30:00Z"]
            ]]
            return (.make(r.url, 200), try json(["items": items]))
        }
        return (.make(r.url, 404), Data())
    }

    private func json(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj)
    }
}

/// A token provider that always returns a fixed access token (auth is tested separately).
private struct StubTokenProvider: AccessTokenProviding {
    let token: String
    func validAccessToken() async throws -> String { token }
}

final class GoogleCalendarRESTClientTests: XCTestCase {

    override func tearDown() { MockURLProtocol.reset(); super.tearDown() }

    private func makeClient() -> GoogleCalendarRESTClient {
        GoogleCalendarRESTClient(
            tokenProvider: StubTokenProvider(token: "acc"),
            transport: MockURLProtocol.transport(),
            clock: FakeClock(now: Date(timeIntervalSince1970: 0)),
            retryPolicy: .none)
    }

    func test_listEvents_readsRealCalendar() async throws {
        let server = FakeCalendarServer()
        MockURLProtocol.handler = { try server.respond($0) }
        let client = makeClient()
        let events = try await client.listEvents(calendarID: "primary",
                                                 from: Date(timeIntervalSince1970: 0),
                                                 to: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.title, "Standup")
        XCTAssertFalse(events.first?.isAgentOwned ?? true, "real calendar events are not agent-owned")
    }

    func test_ensureAgentCalendar_findsOrCreates() async throws {
        let server = FakeCalendarServer()
        MockURLProtocol.handler = { try server.respond($0) }
        let client = makeClient()
        // First call: no agent calendar exists ⇒ it is created.
        let id1 = try await client.ensureAgentCalendar()
        XCTAssertEqual(id1, "agent-cal-id")
        // Second call: found (cached) ⇒ same id, no duplicate creation.
        let id2 = try await client.ensureAgentCalendar()
        XCTAssertEqual(id2, "agent-cal-id")
        let creates = MockURLProtocol.recorded().filter {
            $0.url.path.hasSuffix("/calendar/v3/calendars") && $0.method == "POST"
        }
        XCTAssertEqual(creates.count, 1, "agent calendar created exactly once")
    }

    // ACCEPTANCE: a retried write reuses the same caller event ID ⇒ exactly one event.
    func test_createEvent_idempotentRetry_yieldsExactlyOneEvent() async throws {
        let server = FakeCalendarServer()
        MockURLProtocol.handler = { try server.respond($0) }
        let client = makeClient()
        _ = try await client.ensureAgentCalendar()

        let event = CalendarEventDTO(id: "ignored", calendarID: "agent", title: "Long run",
                                     start: Date(timeIntervalSince1970: 100),
                                     end: Date(timeIntervalSince1970: 200), isAgentOwned: true)

        // First write.
        let created = try await client.createEvent(event, idempotencyKey: "proposal-99")
        // Simulated retry with the SAME idempotency key (e.g. the first response was lost).
        let retried = try await client.createEvent(event, idempotencyKey: "proposal-99")

        XCTAssertEqual(created.id, retried.id, "both attempts resolve to the same event")
        XCTAssertEqual(server.createdEventIDs.count, 1, "server holds exactly one event")

        // Assert the request bodies: both POSTs carried the SAME derived Google event ID.
        let postBodies = MockURLProtocol.recorded()
            .filter { $0.url.path.hasSuffix("/events") && $0.method == "POST" }
            .compactMap { $0.json?["id"] as? String }
        XCTAssertEqual(postBodies.count, 2, "two create attempts were made")
        XCTAssertEqual(Set(postBodies).count, 1, "both attempts reused one caller-provided event ID")
        XCTAssertEqual(postBodies.first, GoogleEventID.make(from: "proposal-99"))
    }

    // SAFETY RULE #2: a write aimed at a real (non-agent) calendar is refused.
    func test_write_toNonAgentCalendar_isRefused() async throws {
        let server = FakeCalendarServer()
        MockURLProtocol.handler = { try server.respond($0) }
        let client = makeClient()
        let realCalEvent = CalendarEventDTO(id: "x", calendarID: "primary", title: "Sneaky",
                                            start: Date(), end: Date(), isAgentOwned: false)
        do {
            _ = try await client.createEvent(realCalEvent, idempotencyKey: "k")
            XCTFail("write to a real calendar must be refused")
        } catch let error as AppError {
            guard case .integration(.unavailable(.calendar, let reason)) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("non-agent"))
        }
        // Nothing was created on the server.
        XCTAssertTrue(server.createdEventIDs.isEmpty)
    }
}
