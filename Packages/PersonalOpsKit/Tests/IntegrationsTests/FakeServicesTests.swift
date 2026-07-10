import XCTest
import Core
import Integrations
@testable import Fixtures

final class FakeServicesTests: XCTestCase {

    func test_fakeCalendar_hasSeedEvents_andConformsToProtocol() async throws {
        let api: any GoogleCalendarAPI = FakeGoogleCalendarAPI.seeded()
        let events = try await api.listEvents(
            calendarID: "primary",
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: .greatestFiniteMagnitude / 2))
        XCTAssertFalse(events.isEmpty, "fixture should ship minimal seed data")
    }

    func test_fakeCalendar_recordsCreateCalls() async throws {
        let api = FakeGoogleCalendarAPI.seeded()
        let event = CalendarEventDTO(id: "evt-1", calendarID: "agent",
                                     title: "Long run", start: Date(timeIntervalSince1970: 100),
                                     end: Date(timeIntervalSince1970: 200), isAgentOwned: true)
        _ = try await api.createEvent(event, idempotencyKey: "evt-1")
        XCTAssertEqual(api.createdEvents.count, 1)
        XCTAssertEqual(api.createdEvents.first?.idempotencyKey, "evt-1")
    }

    func test_fakeGmail_hasSeedMetadata() async throws {
        let api: any GmailAPI = FakeGmailAPI.seeded()
        let msgs = try await api.listRecentMessages(query: nil, since: nil)
        XCTAssertFalse(msgs.isEmpty)
        // Data-boundary: metadata carries ids + dates, not raw bodies.
        XCTAssertNotNil(msgs.first?.messageID)
        XCTAssertNotNil(msgs.first?.threadID)
    }

    func test_fakeHealthKit_hasSeedSummaries() async throws {
        let src: any HealthKitDataSource = FakeHealthKitData.seeded()
        let range = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 1_000_000)
        let summaries = try await src.summary(for: range)
        XCTAssertFalse(summaries.isEmpty)
    }
}
