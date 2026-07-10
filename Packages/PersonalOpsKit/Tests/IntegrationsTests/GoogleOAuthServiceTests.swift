import XCTest
import Core
@testable import Integrations
import Fixtures

final class GoogleOAuthServiceTests: XCTestCase {

    private let config = GoogleOAuthConfig(clientID: "cid.apps.googleusercontent.com")

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func service(clock: Clock = FakeClock(now: Date(timeIntervalSince1970: 1000))) -> GoogleOAuthService {
        GoogleOAuthService(config: config, transport: MockURLProtocol.transport(), clock: clock)
    }

    func test_exchange_parsesTokensAndComputesExpiry() async throws {
        MockURLProtocol.handler = { recorded in
            XCTAssertEqual(recorded.method, "POST")
            // No client secret is ever sent (native PKCE flow).
            XCTAssertFalse(recorded.bodyString?.contains("client_secret") ?? false)
            XCTAssertTrue(recorded.bodyString?.contains("code_verifier") ?? false)
            let body = """
            {"access_token":"acc-1","refresh_token":"ref-1","expires_in":3600,"scope":"s","token_type":"Bearer"}
            """
            return (.make(recorded.url, 200), Data(body.utf8))
        }
        let token = try await service().exchange(code: "code", verifier: "verifier")
        XCTAssertEqual(token.accessToken, "acc-1")
        XCTAssertEqual(token.refreshToken, "ref-1")
        // Expiry = clock.now (1000) + expires_in (3600).
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 4600))
    }

    func test_refresh_returnsNewAccessTokenAndKeepsRefreshToken() async throws {
        MockURLProtocol.handler = { recorded in
            XCTAssertTrue(recorded.bodyString?.contains("grant_type=refresh_token") ?? false)
            // Google omits the refresh token on refresh responses.
            let body = #"{"access_token":"acc-2","expires_in":3600,"token_type":"Bearer"}"#
            return (.make(recorded.url, 200), Data(body.utf8))
        }
        let token = try await service().refresh(refreshToken: "ref-1")
        XCTAssertEqual(token.accessToken, "acc-2")
        XCTAssertEqual(token.refreshToken, "ref-1", "existing refresh token is preserved")
    }

    func test_refresh_invalidGrant_mapsToTokenRevoked() async throws {
        MockURLProtocol.handler = { recorded in
            let body = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
            return (.make(recorded.url, 400), Data(body.utf8))
        }
        do {
            _ = try await service().refresh(refreshToken: "dead")
            XCTFail("expected tokenRevoked")
        } catch let error as AppError {
            XCTAssertEqual(error, .integration(.tokenRevoked(source: .calendar)))
        }
    }
}
