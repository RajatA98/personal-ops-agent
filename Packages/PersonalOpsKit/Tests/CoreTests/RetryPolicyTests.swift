import XCTest
@testable import Core

final class RetryPolicyTests: XCTestCase {

    func test_exponentialBackoff_growsPerAttempt() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1.0, multiplier: 2.0, jitter: false)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4.0, accuracy: 0.0001)
    }

    func test_shouldRetry_respectsMaxAttempts() {
        let policy = RetryPolicy.standard
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 1))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: policy.maxAttempts))
    }

    func test_none_neverRetries() {
        XCTAssertFalse(RetryPolicy.none.shouldRetry(afterAttempt: 1))
    }

    func test_jitter_staysWithinBounds() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1.0, multiplier: 2.0, jitter: true)
        // attempt 2 nominal is 2.0; jitter must stay in [1.0, 2.0]
        for _ in 0..<50 {
            let d = policy.delay(forAttempt: 2)
            XCTAssertGreaterThanOrEqual(d, 1.0)
            XCTAssertLessThanOrEqual(d, 2.0)
        }
    }
}
