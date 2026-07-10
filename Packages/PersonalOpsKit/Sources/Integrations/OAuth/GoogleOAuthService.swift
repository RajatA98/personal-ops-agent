import Foundation
import Core

/// Talks to Google's OAuth token endpoint: exchanges an authorization code for tokens, and
/// silently refreshes an access token from a refresh token. No client secret is sent (native
/// PKCE flow). This type is pure transport + parsing — it holds no tokens and does no
/// storage; `GoogleAuthenticator` orchestrates persistence and degradation on top of it.
public struct GoogleOAuthService: Sendable {
    private let config: GoogleOAuthConfig
    private let transport: HTTPTransport
    private let clock: any Clock

    public init(config: GoogleOAuthConfig, transport: HTTPTransport, clock: any Clock = SystemClock()) {
        self.config = config
        self.transport = transport
        self.clock = clock
    }

    /// Exchange an authorization code (+ PKCE verifier) for the initial token set.
    public func exchange(code: String, verifier: String) async throws -> OAuthToken {
        let form: [String: String] = [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI
        ]
        return try await postToken(form: form, existingRefreshToken: nil)
    }

    /// Silently mint a new access token from a refresh token. If Google rejects the refresh
    /// token (`invalid_grant`), that means it was **revoked or expired** — surfaced as
    /// `IntegrationError.tokenRevoked`, which drives the reconnect state (never a crash).
    public func refresh(refreshToken: String) async throws -> OAuthToken {
        let form: [String: String] = [
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        return try await postToken(form: form, existingRefreshToken: refreshToken)
    }

    // MARK: - Internals

    private func postToken(form: [String: String], existingRefreshToken: String?) async throws -> OAuthToken {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)

        let (data, http) = try await transport.send(request)

        guard (200...299).contains(http.statusCode) else {
            // Distinguish a revoked/expired grant from a generic failure by inspecting the
            // OAuth error body, without ever logging its contents.
            if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
               oauthError.error == "invalid_grant" {
                throw AppError.integration(.tokenRevoked(source: .calendar))
            }
            if http.statusCode == 400 || http.statusCode == 401 {
                throw AppError.auth(.refreshFailed)
            }
            throw HTTPErrorMapper.error(for: http.statusCode, source: .calendar, body: data)
                ?? AppError.auth(.refreshFailed)
        }

        let decoded: TokenResponse
        do { decoded = try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw AppError.network(.malformedResponse) }

        let expiresAt = clock.now.addingTimeInterval(TimeInterval(decoded.expiresIn ?? 3600))
        // A refresh response usually omits the refresh token — keep the existing one.
        return OAuthToken(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? existingRefreshToken,
            expiresAt: expiresAt,
            scope: decoded.scope ?? config.scopeString,
            tokenType: decoded.tokenType ?? "Bearer")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }

    // MARK: - Wire DTOs (never persisted; decode-only)

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let scope: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
        let errorDescription: String?
        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}
