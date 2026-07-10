import XCTest
import Core
@testable import Integrations

@MainActor
final class IntegrationStatusStoreTests: XCTestCase {

    func test_initialState_isDisconnectedAndUnavailable() {
        let store = IntegrationStatusStore()
        let cal = store.status(for: .calendar)
        XCTAssertEqual(cal?.connection, .disconnected)
        XCTAssertEqual(cal?.freshness.status(asOf: Date()), .unavailable)
        XCTAssertNil(cal?.degraded)
    }

    func test_reportSynced_marksConnectedAndFresh() async {
        let store = IntegrationStatusStore()
        let now = Date(timeIntervalSince1970: 10_000)
        await store.reportSynced(.calendar, at: now, threshold: 900)
        let cal = store.status(for: .calendar)
        XCTAssertEqual(cal?.connection, .connected)
        XCTAssertEqual(cal?.freshness.status(asOf: now), .fresh)
        XCTAssertNil(cal?.degraded)
    }

    // Phase 4A reads these degraded states to surface reconnect prompts.
    func test_reportDegraded_reconnect_setsReconnectRequired() async {
        let store = IntegrationStatusStore()
        await store.reportConnected(.gmail, syncedAt: Date(), threshold: 900)
        await store.reportDegraded(.gmail, .reconnectRequired(source: .gmail))
        let gmail = store.status(for: .gmail)
        XCTAssertEqual(gmail?.connection, .reconnectRequired)
        XCTAssertEqual(gmail?.degraded, .reconnectRequired(source: .gmail))
    }

    func test_reportDisconnected_clearsState() async {
        let store = IntegrationStatusStore()
        await store.reportConnected(.calendar, syncedAt: Date(), threshold: 900)
        await store.reportDisconnected(.calendar)
        let cal = store.status(for: .calendar)
        XCTAssertEqual(cal?.connection, .disconnected)
        XCTAssertNil(cal?.degraded)
    }

    func test_ordered_isStableManagedSet() {
        let store = IntegrationStatusStore()
        XCTAssertEqual(store.ordered.map(\.source), [.calendar, .gmail])
    }
}
