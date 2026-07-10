import Foundation
import Core

/// Builds the Google authorization request URL for the PKCE consent step. Pure and
/// deterministic given a config, PKCE pair, and state — so it is fully unit-testable
/// without ever presenting a browser.
public struct AuthorizationRequest: Equatable, Sendable {
    public let config: GoogleOAuthConfig
    public let pkce: PKCE
    /// Opaque CSRF token echoed back on the callback and verified before exchanging.
    public let state: String

    public init(config: GoogleOAuthConfig, pkce: PKCE, state: String = AuthorizationRequest.randomState()) {
        self.config = config
        self.pkce = pkce
        self.state = state
    }

    /// The full authorization URL to load in `ASWebAuthenticationSession`.
    public var url: URL {
        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopeString),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            // Request a refresh token and force the consent screen so we reliably receive one.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    /// Parse the authorization code from the redirect callback URL, validating `state`.
    /// Returns the code, or throws the appropriate `AppError`.
    public func parseCallback(_ callback: URL) throws -> String {
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            // User denied consent, or the request was rejected.
            if error == "access_denied" { throw AppError.auth(.consentCancelled) }
            throw AppError.auth(.refreshFailed)
        }
        guard let returnedState = items.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
            // State mismatch → possible CSRF; refuse to proceed.
            throw AppError.auth(.refreshFailed)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AppError.auth(.refreshFailed)
        }
        return code
    }

    public static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64URLEncodedString()
    }
}
