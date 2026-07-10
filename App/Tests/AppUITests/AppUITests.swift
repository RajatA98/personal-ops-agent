import XCTest

/// Minimal UI test proving the app shell launches on the simulator. Phase 3B+ adds real
/// flow coverage (briefing, capture, Ops Inbox).
final class AppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_appLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
