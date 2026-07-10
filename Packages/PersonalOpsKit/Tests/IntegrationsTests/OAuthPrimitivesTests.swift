import XCTest
import Core
@testable import Integrations

final class OAuthPrimitivesTests: XCTestCase {

    // MARK: PKCE

    func test_pkce_challenge_isDeterministicS256() {
        // Known RFC 7636 Appendix B vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func test_pkce_generate_producesUnreservedCharsetVerifier() {
        let pkce = PKCE.generate()
        XCTAssertGreaterThanOrEqual(pkce.codeVerifier.count, 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(pkce.codeVerifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(pkce.method, "S256")
        XCTAssertEqual(pkce.codeChallenge, PKCE.challenge(for: pkce.codeVerifier))
    }

    // MARK: Authorization request

    func test_authorizationURL_carriesPKCEAndScopesAndRedirect() throws {
        let config = GoogleOAuthConfig(clientID: "123-abc.apps.googleusercontent.com")
        let pkce = PKCE(codeVerifier: "verifier-123")
        let request = AuthorizationRequest(config: config, pkce: pkce, state: "state-xyz")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(value("client_id"), "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), pkce.codeChallenge)
        XCTAssertEqual(value("state"), "state-xyz")
        XCTAssertEqual(value("redirect_uri"), "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(value("access_type"), "offline")
        // Minimal scope set: read-only calendar, app-created calendar, read-only gmail.
        let scope = value("scope") ?? ""
        XCTAssertTrue(scope.contains("calendar.readonly"))
        XCTAssertTrue(scope.contains("calendar.app.created"))
        XCTAssertTrue(scope.contains("gmail.readonly"))
        // Never requests a write-all or send scope (Safety Rules #2/#4).
        XCTAssertFalse(scope.contains("auth/calendar.events"))
        XCTAssertFalse(scope.contains("gmail.send"))
        XCTAssertFalse(scope.contains("gmail.modify"))
    }

    func test_redirectScheme_isReversedClientID() {
        let config = GoogleOAuthConfig(clientID: "999-xyz.apps.googleusercontent.com")
        XCTAssertEqual(config.redirectScheme, "com.googleusercontent.apps.999-xyz")
    }

    func test_parseCallback_rejectsStateMismatch() {
        let config = GoogleOAuthConfig(clientID: "1.apps.googleusercontent.com")
        let request = AuthorizationRequest(config: config, pkce: PKCE(codeVerifier: "v"), state: "expected")
        let bad = URL(string: "com.x:/oauth2redirect?code=abc&state=attacker")!
        XCTAssertThrowsError(try request.parseCallback(bad)) { error in
            XCTAssertEqual(error as? AppError, .auth(.refreshFailed))
        }
    }

    func test_parseCallback_reportsUserCancellation() {
        let config = GoogleOAuthConfig(clientID: "1.apps.googleusercontent.com")
        let request = AuthorizationRequest(config: config, pkce: PKCE(codeVerifier: "v"), state: "s")
        let denied = URL(string: "com.x:/oauth2redirect?error=access_denied&state=s")!
        XCTAssertThrowsError(try request.parseCallback(denied)) { error in
            XCTAssertEqual(error as? AppError, .auth(.consentCancelled))
        }
    }

    func test_parseCallback_extractsCode() throws {
        let config = GoogleOAuthConfig(clientID: "1.apps.googleusercontent.com")
        let request = AuthorizationRequest(config: config, pkce: PKCE(codeVerifier: "v"), state: "s")
        let ok = URL(string: "com.x:/oauth2redirect?code=the-code&state=s")!
        XCTAssertEqual(try request.parseCallback(ok), "the-code")
    }

    // MARK: OAuthToken

    func test_token_isExpired_respectsLeeway() {
        let now = Date(timeIntervalSince1970: 1000)
        let token = OAuthToken(accessToken: "a", refreshToken: "r",
                               expiresAt: Date(timeIntervalSince1970: 1030),
                               scope: "s")
        // 30s to expiry, default 60s leeway ⇒ treated as expired.
        XCTAssertTrue(token.isExpired(asOf: now))
        // With no leeway it is still valid.
        XCTAssertFalse(token.isExpired(asOf: now, leeway: 0))
    }

    func test_token_descriptionNeverLeaksSecrets() {
        let token = OAuthToken(accessToken: "ya29.SECRET-ACCESS", refreshToken: "1//SECRET-REFRESH",
                               expiresAt: Date(), scope: "s")
        let text = "\(token)" + token.debugDescription
        XCTAssertFalse(text.contains("SECRET-ACCESS"))
        XCTAssertFalse(text.contains("SECRET-REFRESH"))
        XCTAssertTrue(text.contains("<redacted>"))
    }

    // MARK: GoogleEventID

    func test_eventID_isDeterministicAndValid() {
        let a = GoogleEventID.make(from: "proposal-42")
        let b = GoogleEventID.make(from: "proposal-42")
        let c = GoogleEventID.make(from: "proposal-43")
        XCTAssertEqual(a, b, "same idempotency key ⇒ same Google event ID")
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(GoogleEventID.isValid(a), "must be base32hex, length 5–1024")
    }
}
