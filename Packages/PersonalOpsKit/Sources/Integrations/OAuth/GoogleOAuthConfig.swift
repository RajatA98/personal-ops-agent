import Foundation

/// Endpoints, scopes, and redirect handling for the user-owned Google OAuth client
/// (LOCKED_DECISIONS #4/#8: direct REST, ASWebAuthenticationSession, native PKCE, no secret).
///
/// ## Scope choice (justified here and in docs/GOOGLE_SETUP.md)
/// We request the **narrowest scopes that let the app do its job**:
///
/// - `calendar.readonly` — read the user's real calendars. Reading real events is a hard
///   requirement (Morning Briefing). This is a broad *read* grant, but read-only: it can
///   never modify anything.
/// - `calendar.app.created` — create a dedicated secondary calendar and read/write events
///   **only on calendars this app created**. This is the key safety property: the token is
///   *structurally* incapable of writing to the user's primary/real calendars (Safety Rule
///   #2), so even a bug can't. We deliberately reject the broader `calendar.events`
///   (read+write on ALL calendars) for exactly this reason.
/// - `gmail.readonly` — list/search messages and read the metadata + snippet needed to
///   classify plan-like email into Proposals (Phase 4B). We considered the narrower
///   `gmail.metadata`, but it forbids the search query (`q`) parameter and the message
///   snippet that classification needs; so we take `gmail.readonly` and *self-limit what we
///   store* to the data-boundary set (ids, dates, snippet) — never full bodies.
public struct GoogleOAuthConfig: Equatable, Sendable {

    // MARK: Scopes

    /// Read the user's real calendars (never write).
    public static let scopeCalendarReadonly = "https://www.googleapis.com/auth/calendar.readonly"
    /// Create + manage events ONLY on app-created calendars (the agent-owned calendar).
    public static let scopeCalendarAppCreated = "https://www.googleapis.com/auth/calendar.app.created"
    /// Read-only Gmail (list/search + metadata/snippet). No send scope, ever (Safety Rule #4).
    public static let scopeGmailReadonly = "https://www.googleapis.com/auth/gmail.readonly"

    /// The full, minimal scope set the app requests at consent.
    public static let requestedScopes = [
        scopeCalendarReadonly,
        scopeCalendarAppCreated,
        scopeGmailReadonly
    ]

    // MARK: Endpoints

    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL

    /// The OAuth 2.0 client ID from the user-owned Google Cloud project (iOS client type).
    public let clientID: String
    /// Scopes to request.
    public let scopes: [String]

    public init(clientID: String,
                scopes: [String] = GoogleOAuthConfig.requestedScopes,
                authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
                revocationEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!) {
        self.clientID = clientID
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
    }

    /// The single space-separated scope string sent to Google.
    public var scopeString: String { scopes.joined(separator: " ") }

    // MARK: Redirect URI (reversed-client-ID scheme, required for Google iOS clients)

    /// Google iOS OAuth clients use the **reversed client ID** as a custom URL scheme.
    /// For a client ID `1234-abc.apps.googleusercontent.com`, the scheme is
    /// `com.googleusercontent.apps.1234-abc`. This is the value
    /// `ASWebAuthenticationSession` matches its callback against.
    public var redirectScheme: String {
        // Client ID form: "<id>.apps.googleusercontent.com" → reversed:
        // "com.googleusercontent.apps.<id>".
        let suffix = ".apps.googleusercontent.com"
        if clientID.hasSuffix(suffix) {
            let id = String(clientID.dropLast(suffix.count))
            return "com.googleusercontent.apps.\(id)"
        }
        // Fallback: reverse the dotted components (keeps behaviour defined for odd inputs).
        return clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    /// The full redirect URI (`<scheme>:/oauth2redirect`). The path is a Google convention.
    public var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
}
