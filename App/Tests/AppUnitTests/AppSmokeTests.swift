import XCTest
import Core
import Integrations
import Reasoning
import Fixtures

/// App-target smoke tests. Phase 0's acceptance criterion #2: `xcodebuild test` passes
/// "with the fixture services wired in but unused." These construct every fixture to
/// prove the app target links `PersonalOpsKit` + `Fixtures` and the contracts compile,
/// without exercising real behavior (that begins in Phase 2+).
final class AppSmokeTests: XCTestCase {

    func test_fixtureServicesAreWireable() {
        let calendar: any GoogleCalendarAPI = FakeGoogleCalendarAPI.seeded()
        let gmail: any GmailAPI = FakeGmailAPI.seeded()
        let health: any HealthKitDataSource = FakeHealthKitData.seeded()
        let reasoning: any ReasoningProvider = FakeReasoningProvider(scriptedText: "ok")
        let clock: any Clock = FakeClock()

        // Wired in but unused — just prove they exist and conform.
        XCTAssertNotNil(calendar)
        XCTAssertNotNil(gmail)
        XCTAssertNotNil(health)
        XCTAssertNotNil(reasoning)
        XCTAssertNotNil(clock)
    }

    func test_coreContractsAvailableToApp() {
        XCTAssertTrue(AppError.network(.timeout).isRetryable)
        let freshness = SourceFreshness(source: .calendar,
                                        lastSuccessfulSync: nil,
                                        stalenessThreshold: 3600)
        XCTAssertTrue(freshness.isDegraded(asOf: Date()))
    }
}
