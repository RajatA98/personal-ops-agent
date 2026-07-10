import XCTest
import Core
@testable import Integrations
import Fixtures

@MainActor
final class GoogleAuthenticatorTests: XCTestCase {

    private let config = GoogleOAuthConfig(clientID: "cid.apps.googleusercontent.com")

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeAuthenticator(
        tokenStore: TokenStore,
        status: IntegrationStatusStore,
        codeProvider: AuthorizationCodeProvider = FakeAuthorizationCodeProvider(),
        clock: Clock
    ) -> GoogleAuthenticator {
        GoogleAuthenticator(
            config: config,
            tokenStore: tokenStore,
            codeProvider: codeProvider,
            status: status,
            transport: MockURLProtocol.transport(),
            clock: clock)
    }

    // MARK: One-time consent

    func test_connect_exchangesCode_persistsToken_andReportsConnected() async throws {
        MockURLProtocol.handler = { recorded in
            let body = #"{"access_token":"acc","refresh_token":"ref","expires_in":3600,"token_type":"Bearer"}"#
            return (.make(recorded.url, 200), Data(body.utf8))
        }
        let store = InMemoryTokenStore()
        let status = IntegrationStatusStore()
        let auth = makeAuthenticator(tokenStore: store, status: status,
                                     clock: FakeClock(now: Date(timeIntervalSince1970: 0)))

        try await auth.connect()

        XCTAssertEqual(store.peek(account: "google")?.accessToken, "acc")
        XCTAssertEqual(status.status(for: .calendar)?.connection, .connected)
        XCTAssertEqual(status.status(for: .gmail)?.connection, .connected)
    }

    // MARK: Silent refresh (acceptance: tested against an EXPIRED access token)

    func test_validAccessToken_refreshesExpiredToken() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 10_000))
        // Stored token already expired (expiresAt < now).
        let expired = OAuthToken(accessToken: "old-access", refreshToken: "ref",
                                 expiresAt: Date(timeIntervalSince1970: 5_000), scope: "s")
        let store = InMemoryTokenStore(seed: ["google": expired])
        let status = IntegrationStatusStore()

        MockURLProtocol.handler = { recorded in
            XCTAssertTrue(recorded.bodyString?.contains("grant_type=refresh_token") ?? false)
            let body = #"{"access_token":"new-access","expires_in":3600,"token_type":"Bearer"}"#
            return (.make(recorded.url, 200), Data(body.utf8))
        }

        let auth = makeAuthenticator(tokenStore: store, status: status, clock: clock)
        let access = try await auth.validAccessToken()

        XCTAssertEqual(access, "new-access", "expired token is silently refreshed")
        XCTAssertEqual(store.peek(account: "google")?.accessToken, "new-access",
                       "refreshed token is persisted for reuse")
        XCTAssertEqual(store.peek(account: "google")?.refreshToken, "ref",
                       "refresh token is retained across refresh")
    }

    func test_validAccessToken_usesStoredTokenWhenStillValid() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000))
        let valid = OAuthToken(accessToken: "still-good", refreshToken: "ref",
                               expiresAt: Date(timeIntervalSince1970: 9_999), scope: "s")
        let store = InMemoryTokenStore(seed: ["google": valid])
        // No handler set — a network call would fail, proving no refresh happens.
        let auth = makeAuthenticator(tokenStore: store, status: IntegrationStatusStore(), clock: clock)
        let access = try await auth.validAccessToken()
        XCTAssertEqual(access, "still-good")
        XCTAssertTrue(MockURLProtocol.recorded().isEmpty, "valid token ⇒ no network refresh")
    }

    // MARK: Revoked refresh token → visible reconnect state (acceptance: no crash/silent fail)

    func test_revokedRefreshToken_producesReconnectState_notCrash() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 10_000))
        let expired = OAuthToken(accessToken: "old", refreshToken: "revoked-ref",
                                 expiresAt: Date(timeIntervalSince1970: 5_000), scope: "s")
        let store = InMemoryTokenStore(seed: ["google": expired])
        let status = IntegrationStatusStore()

        MockURLProtocol.handler = { recorded in
            let body = #"{"error":"invalid_grant","error_description":"revoked"}"#
            return (.make(recorded.url, 400), Data(body.utf8))
        }

        let auth = makeAuthenticator(tokenStore: store, status: status, clock: clock)

        do {
            _ = try await auth.validAccessToken()
            XCTFail("expected tokenRevoked to surface")
        } catch let error as AppError {
            XCTAssertEqual(error, .integration(.tokenRevoked(source: .calendar)))
        }

        // Visible reconnect state recorded for BOTH sources the grant covers.
        XCTAssertEqual(status.status(for: .calendar)?.connection, .reconnectRequired)
        XCTAssertEqual(status.status(for: .gmail)?.connection, .reconnectRequired)
        XCTAssertEqual(status.status(for: .calendar)?.degraded,
                       .reconnectRequired(source: .calendar))
        // Dead refresh token is removed so we don't loop on it.
        XCTAssertNil(store.peek(account: "google"))
    }

    func test_disconnect_deletesToken_andReportsDisconnected() async throws {
        let token = OAuthToken(accessToken: "a", refreshToken: "r",
                               expiresAt: Date(timeIntervalSince1970: 9_999), scope: "s")
        let store = InMemoryTokenStore(seed: ["google": token])
        let status = IntegrationStatusStore()
        MockURLProtocol.handler = { r in (.make(r.url, 200), Data()) } // revoke endpoint
        let auth = makeAuthenticator(tokenStore: store, status: status,
                                     clock: FakeClock(now: Date(timeIntervalSince1970: 0)))

        try await auth.disconnect()

        XCTAssertNil(store.peek(account: "google"))
        XCTAssertEqual(status.status(for: .calendar)?.connection, .disconnected)
        XCTAssertEqual(status.status(for: .gmail)?.connection, .disconnected)
    }
}
