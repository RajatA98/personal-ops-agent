import Foundation

/// An OAuth 2.0 token set for a single Google account/integration.
///
/// This is **local-only, never-sent** data (PRD Data Boundaries): the access and refresh
/// tokens live in the iOS Keychain and are never logged (Safety Rule #5). `Codable` here is
/// only so the token can be serialized *into the Keychain* — it never crosses the network or
/// enters a log. `description`/`debugDescription` are deliberately redacted so an accidental
/// string-interpolation of a token cannot leak it.
public struct OAuthToken: Equatable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The short-lived bearer token sent on API requests.
    public let accessToken: String
    /// The long-lived token used to silently mint new access tokens. May be absent on a
    /// refresh response (Google only returns it on the initial consent).
    public let refreshToken: String?
    /// Absolute time the access token stops being valid.
    public let expiresAt: Date
    /// The space-separated scope string the token was granted.
    public let scope: String
    /// Token type — always `Bearer` for Google.
    public let tokenType: String

    public init(accessToken: String,
                refreshToken: String?,
                expiresAt: Date,
                scope: String,
                tokenType: String = "Bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    /// Whether the access token is expired (or within `leeway` of expiring) as of `now`.
    /// A small leeway avoids sending a token that will expire mid-flight.
    public func isExpired(asOf now: Date, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }

    /// The `Authorization` header value. Kept as a computed property (not stored) so it is
    /// never accidentally persisted alongside other fields.
    public var authorizationHeaderValue: String { "\(tokenType) \(accessToken)" }

    /// Redacted — a token must never render its secret material in a string (Safety Rule #5).
    public var description: String {
        "OAuthToken(scope: \"\(scope)\", expiresAt: \(expiresAt), accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "nil" : "<redacted>"))"
    }
    public var debugDescription: String { description }
}
