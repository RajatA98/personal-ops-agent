import XCTest
import SwiftData
import Core
import Data
import Integrations
import Fixtures
@testable import Proposals

/// mark-as-wrong records a durable rejection signal (Phase 4B), and reconnect states surface
/// as informational Inbox alerts (never executable proposals).
@MainActor
final class RejectionAndAlertTests: XCTestCase {

    func test_markAsWrong_dismisses_andRecordsRejectionSignal() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let spies = ProposalType.allCases.map { SpyHandler($0) }
        let eng = ProposalEngine(context: ctx, clock: clock, handlers: spies)

        let p = PX.pending(.rememberFact, payload: ["k": "v"])
        try eng.enqueue(p)
        let signal = try eng.markAsWrong(p, sourcePattern: "gmail:noreply@jobs.example.com")

        // Never executes; becomes dismissed.
        XCTAssertTrue(spies.allSatisfy { $0.executeCount == 0 })
        XCTAssertEqual(p.status, .dismissed)

        // The signal is persisted in the documented shape (a Pattern), readable by 4B.
        let store = MemoryStore(context: ctx, clock: clock)
        let rejStore = RejectionSignalStore(store: store)
        XCTAssertEqual(try rejStore.strength(forSourcePattern: "gmail:noreply@jobs.example.com"), 1)
        XCTAssertEqual(signal.proposalType, .rememberFact)
        XCTAssertEqual(signal.sourcePattern, "gmail:noreply@jobs.example.com")

        // A second rejection of the same pattern reinforces (occurrences bump), append-only.
        let p2 = PX.pending(.rememberFact, payload: ["k": "v"])
        try eng.enqueue(p2)
        _ = try eng.markAsWrong(p2, sourcePattern: "gmail:noreply@jobs.example.com")
        XCTAssertEqual(try rejStore.strength(forSourcePattern: "gmail:noreply@jobs.example.com"), 2)
        // History preserved: two Pattern revisions for the one factKey.
        XCTAssertEqual(try store.history(Pattern.self, factKey: signal.factKey).count, 2)
    }

    func test_markAsWrong_defaultsSourcePatternToFactKey() throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let eng = ProposalEngine(context: ctx, clock: clock, handlers: [])
        let p = PX.pending(.dismissSignal, payload: ["k": "v"], factKey: "proposal:signal:abc")
        try eng.enqueue(p)
        let signal = try eng.markAsWrong(p)
        XCTAssertEqual(signal.sourcePattern, "proposal:signal:abc")
    }

    func test_reconnectState_surfacesAsInformationalAlert() async {
        let status = IntegrationStatusStore()
        await status.reportConnected(.calendar, syncedAt: PX.now, threshold: 900)
        await status.reportDegraded(.gmail, .reconnectRequired(source: .gmail))

        let alerts = IntegrationAlertBuilder.alerts(from: status)
        XCTAssertEqual(alerts.count, 1, "only the reconnect-required integration produces an alert")
        XCTAssertEqual(alerts.first?.source, .gmail)
        XCTAssertTrue(alerts.first?.title.contains("Reconnect") == true)
    }

    func test_noReconnect_noAlerts() async {
        let status = IntegrationStatusStore()
        await status.reportConnected(.calendar, syncedAt: PX.now, threshold: 900)
        await status.reportConnected(.gmail, syncedAt: PX.now, threshold: 900)
        XCTAssertTrue(IntegrationAlertBuilder.alerts(from: status).isEmpty)
    }
}
