import XCTest
@testable import Core

final class RedactingLoggerTests: XCTestCase {

    func test_bearerToken_isRedacted() {
        let logger = RedactingLogger()
        let out = logger.redact("Authorization: Bearer ya29.a0AfB_secretTokenValue123")
        XCTAssertFalse(out.contains("ya29.a0AfB_secretTokenValue123"))
        XCTAssertTrue(out.contains("[REDACTED]"))
    }

    func test_email_isRedacted() {
        let logger = RedactingLogger()
        let out = logger.redact("user rajat1998@gmail.com signed in")
        XCTAssertFalse(out.contains("rajat1998@gmail.com"))
    }

    func test_googleApiKeyPattern_isRedacted() {
        let logger = RedactingLogger()
        let key = "AIzaSyD-1234567890abcdefghijklmnopqrstuv"
        let out = logger.redact("key=\(key)")
        XCTAssertFalse(out.contains(key))
    }

    func test_registeredSecret_isAlwaysRedacted() {
        // Secrets from Config are registered so they are scrubbed even without a pattern.
        var logger = RedactingLogger()
        logger.registerSecret("super-custom-elevenlabs-key-xyz")
        let out = logger.redact("calling tts with key super-custom-elevenlabs-key-xyz")
        XCTAssertFalse(out.contains("super-custom-elevenlabs-key-xyz"))
        XCTAssertTrue(out.contains("[REDACTED]"))
    }

    func test_ordinaryMessage_passesThrough() {
        let logger = RedactingLogger()
        XCTAssertEqual(logger.redact("briefing assembled with 3 events"),
                       "briefing assembled with 3 events")
    }
}
