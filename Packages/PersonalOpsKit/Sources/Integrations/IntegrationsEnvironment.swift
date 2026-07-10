import Foundation
import Core

/// Composition root for the Phase 2 Google integrations: wires the Keychain token store, the
/// OAuth authenticator, the Calendar/Gmail REST clients, and the observable status store into
/// one object the app injects into the UI.
///
/// Two builders:
///   • `live(clientID:)` — real OAuth against the user's Google client (needs a client ID
///     from `Secrets/Config.local`).
///   • `unconfigured()` — no client ID yet: the status store still renders (all disconnected),
///     and the controller surfaces a clear "add your Google client ID" configuration error
///     instead of crashing (graceful degradation, PRD Integration Failure Modes).
@MainActor
public final class IntegrationsEnvironment {
    public let status: IntegrationStatusStore
    public let controller: any IntegrationController
    public let calendar: (any GoogleCalendarAPI)?
    public let gmail: (any GmailAPI)?
    public let gmailMetadata: (any GmailMetadataStore)?

    private init(status: IntegrationStatusStore,
                 controller: any IntegrationController,
                 calendar: (any GoogleCalendarAPI)?,
                 gmail: (any GmailAPI)?,
                 gmailMetadata: (any GmailMetadataStore)?) {
        self.status = status
        self.controller = controller
        self.calendar = calendar
        self.gmail = gmail
        self.gmailMetadata = gmailMetadata
    }

    /// Build the live environment for a user-owned Google OAuth client ID.
    ///
    /// `metadataStore` is injectable so Phase 4B can supply its durable, SwiftData-backed
    /// `GmailMetadataStore` (thread dedupe surviving relaunch) without `Integrations` having to
    /// depend on `Data`/`Signals` (which would form a cycle — `Signals` imports the protocol from
    /// here). When omitted, it defaults to the Phase 2 in-memory store.
    public static func live(clientID: String,
                            tokenStore: TokenStore = KeychainTokenStore(),
                            transport: HTTPTransport = URLSessionTransport(),
                            codeProvider: AuthorizationCodeProvider = makeDefaultCodeProvider(),
                            clock: any Clock = SystemClock(),
                            metadataStore: (any GmailMetadataStore)? = nil) -> IntegrationsEnvironment {
        let status = IntegrationStatusStore()
        let config = GoogleOAuthConfig(clientID: clientID)
        let authenticator = GoogleAuthenticator(
            config: config,
            tokenStore: tokenStore,
            codeProvider: codeProvider,
            status: status,
            transport: transport,
            clock: clock)
        let metadata = metadataStore ?? InMemoryGmailMetadataStore()
        let calendar = GoogleCalendarRESTClient(tokenProvider: authenticator,
                                                transport: transport, status: status, clock: clock)
        let gmail = GmailRESTClient(tokenProvider: authenticator, transport: transport,
                                    metadataStore: metadata, status: status, clock: clock)
        return IntegrationsEnvironment(status: status, controller: authenticator,
                                       calendar: calendar, gmail: gmail, gmailMetadata: metadata)
    }

    /// Build an environment with no configured client ID (e.g. `Secrets/Config.local` absent).
    public static func unconfigured() -> IntegrationsEnvironment {
        let status = IntegrationStatusStore()
        return IntegrationsEnvironment(status: status,
                                       controller: UnconfiguredController(),
                                       calendar: nil, gmail: nil, gmailMetadata: nil)
    }

    /// Default real consent presenter (falls back to a never-succeeding provider on platforms
    /// without `AuthenticationServices`, which never happens on iOS/macOS).
    public static func makeDefaultCodeProvider() -> AuthorizationCodeProvider {
        #if canImport(AuthenticationServices)
        return WebAuthorizationCodeProvider()
        #else
        return UnavailableCodeProvider()
        #endif
    }
}

/// Controller used when no Google client ID is configured: every action fails with a clear,
/// secret-free configuration error the Settings screen can display.
private struct UnconfiguredController: IntegrationController {
    func connect() async throws {
        throw AppError.configuration(.missingKey("GOOGLE_OAUTH_CLIENT_ID"))
    }
    func disconnect() async throws {}
    func isConnected() async -> Bool { false }
}

#if !canImport(AuthenticationServices)
private struct UnavailableCodeProvider: AuthorizationCodeProvider {
    func authorize(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        throw AppError.auth(.refreshFailed)
    }
}
#endif
