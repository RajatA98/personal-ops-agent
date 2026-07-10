import XCTest
@testable import Core

final class ConfigTests: XCTestCase {

    func test_parsesWellFormedFile() throws {
        let contents = """
        # Personal Ops Agent local secrets
        GOOGLE_OAUTH_CLIENT_ID=1234-abc.apps.googleusercontent.com
        GEMINI_API_KEY=AIzaSyFAKE
        ELEVENLABS_API_KEY=el_fake_key

        """
        let config = try Config.parse(contents)
        XCTAssertEqual(config.googleOAuthClientID, "1234-abc.apps.googleusercontent.com")
        XCTAssertEqual(config.geminiAPIKey, "AIzaSyFAKE")
        XCTAssertEqual(config.elevenLabsAPIKey, "el_fake_key")
    }

    func test_ignoresCommentsAndBlankLinesAndWhitespace() throws {
        let contents = """

        # comment
        GOOGLE_OAUTH_CLIENT_ID =  cid
          GEMINI_API_KEY = gk
        ELEVENLABS_API_KEY=ek
        """
        let config = try Config.parse(contents)
        XCTAssertEqual(config.googleOAuthClientID, "cid")
        XCTAssertEqual(config.geminiAPIKey, "gk")
        XCTAssertEqual(config.elevenLabsAPIKey, "ek")
    }

    func test_cloudKitFlag_defaultsOff_whenAbsent() throws {
        let contents = """
        GOOGLE_OAUTH_CLIENT_ID=cid
        GEMINI_API_KEY=gk
        ELEVENLABS_API_KEY=ek
        """
        let config = try Config.parse(contents)
        XCTAssertFalse(config.cloudKitSyncEnabled, "absent CLOUDKIT_SYNC_ENABLED ⇒ off")
    }

    func test_cloudKitFlag_parsesTrue_caseInsensitive() throws {
        let contents = """
        GOOGLE_OAUTH_CLIENT_ID=cid
        GEMINI_API_KEY=gk
        ELEVENLABS_API_KEY=ek
        CLOUDKIT_SYNC_ENABLED=True
        """
        let config = try Config.parse(contents)
        XCTAssertTrue(config.cloudKitSyncEnabled)
    }

    func test_cloudKitFlag_nonTrueValue_isOff() throws {
        let contents = """
        GOOGLE_OAUTH_CLIENT_ID=cid
        GEMINI_API_KEY=gk
        ELEVENLABS_API_KEY=ek
        CLOUDKIT_SYNC_ENABLED=no
        """
        let config = try Config.parse(contents)
        XCTAssertFalse(config.cloudKitSyncEnabled)
    }

    func test_missingKey_throwsConfigError() {
        let contents = "GEMINI_API_KEY=gk\nELEVENLABS_API_KEY=ek\n"
        XCTAssertThrowsError(try Config.parse(contents)) { error in
            guard case ConfigError.missingKey(let key) = error else {
                return XCTFail("expected missingKey, got \(error)")
            }
            XCTAssertEqual(key, "GOOGLE_OAUTH_CLIENT_ID")
        }
    }

    func test_malformedLine_throwsConfigError() {
        let contents = "GOOGLE_OAUTH_CLIENT_ID=cid\nthis line has no equals\nGEMINI_API_KEY=gk\nELEVENLABS_API_KEY=ek"
        XCTAssertThrowsError(try Config.parse(contents)) { error in
            guard case ConfigError.malformedLine = error else {
                return XCTFail("expected malformedLine, got \(error)")
            }
        }
    }
}
