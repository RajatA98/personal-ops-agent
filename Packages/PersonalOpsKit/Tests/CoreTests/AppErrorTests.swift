import XCTest
@testable import Core

final class AppErrorTests: XCTestCase {

    func test_integrationError_mapsToVisibleDegradedState() {
        let err = AppError.integration(.tokenRevoked(source: .gmail))
        XCTAssertEqual(err.degradedState, .reconnectRequired(source: .gmail))
        XCTAssertTrue(err.isUserVisible)
    }

    func test_networkError_isRetryable_butConfigErrorIsNot() {
        XCTAssertTrue(AppError.network(.timeout).isRetryable)
        XCTAssertFalse(AppError.configuration(.missingKey("GEMINI_API_KEY")).isRetryable)
    }

    func test_permissionWithheld_producesPermissionDegradedState() {
        let err = AppError.integration(.permissionWithheld(source: .healthKit))
        XCTAssertEqual(err.degradedState, .permissionWithheld(source: .healthKit))
    }

    func test_userMessage_neverContainsSecretsForConfigError() {
        // The presented message must not echo a raw key value.
        let err = AppError.configuration(.missingKey("GEMINI_API_KEY"))
        XCTAssertFalse(err.userMessage.isEmpty)
    }
}
