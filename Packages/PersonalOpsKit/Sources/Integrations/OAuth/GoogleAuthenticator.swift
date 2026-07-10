import Foundation
import Core

/// Supplies a valid bearer access token to API clients, refreshing silently when needed.
public protocol AccessTokenProviding: Sendable {
    /// A currently-valid access token, refreshing transparently if the stored one expired.
    /// Throws `IntegrationError.tokenRevoked` (→ reconnect state) if the grant is dead.
    func validAccessToken() async throws -> String
}

/// Drives connect / disconnect from the UI (one Google grant covers Calendar + Gmail).
public protocol IntegrationController: Sendable {
    func connect() async throws
    func disconnect() async throws
    func isConnected() async -> Bool
}

/// Orchestrates the full Google OAuth lifecycle for the single `google` account:
///   • **connect** — one-time PKCE consent via `AuthorizationCodeProvider`, token exchange,
///     Keychain persistence.
///   • **validAccessToken** — silent refresh when the access token is expired; a revoked
///     refresh token surfaces `tokenRevoked` and flips the integrations to `reconnectRequired`
///     (visible reconnect state, never a crash — PRD Integration Failure Modes).
///   • **disconnect** — best-effort server revocation + Keychain deletion.
///
/// An `actor` so concurrent Calendar/Gmail calls can't trigger overlapping refreshes.
public actor GoogleAuthenticator: AccessTokenProviding, IntegrationController {

    private let config: GoogleOAuthConfig
    private let service: GoogleOAuthService
    private let tokenStore: TokenStore
    private let codeProvider: AuthorizationCodeProvider
    private let status: IntegrationStatusReporting
    private let transport: HTTPTransport
    private let clock: any Clock
    private let account: String
    /// Sources this single grant covers (reported together).
    private let coveredSources: [DataSource]

    public init(config: GoogleOAuthConfig,
                tokenStore: TokenStore,
                codeProvider: AuthorizationCodeProvider,
                status: IntegrationStatusReporting,
                transport: HTTPTransport,
                clock: any Clock = SystemClock(),
                account: String = TokenAccount.google,
                coveredSources: [DataSource] = [.calendar, .gmail]) {
        self.config = config
        self.service = GoogleOAuthService(config: config, transport: transport, clock: clock)
        self.tokenStore = tokenStore
        self.codeProvider = codeProvider
        self.status = status
        self.transport = transport
        self.clock = clock
        self.account = account
        self.coveredSources = coveredSources
    }

    // MARK: IntegrationController

    public func connect() async throws {
        let pkce = PKCE.generate()
        let request = AuthorizationRequest(config: config, pkce: pkce)
        let callback = try await codeProvider.authorize(
            authorizationURL: request.url,
            callbackScheme: config.redirectScheme)
        let code = try request.parseCallback(callback)
        let token = try await service.exchange(code: code, verifier: pkce.codeVerifier)
        try tokenStore.save(token, account: account)
        for source in coveredSources {
            await status.reportConnected(source, syncedAt: nil, threshold: staleness)
        }
    }

    public func disconnect() async throws {
        // Best-effort server-side revocation so the grant is truly dead (ignore failures —
        // deleting the local token is what actually disconnects this device).
        if let token = try? tokenStore.load(account: account) {
            await revokeOnServer(token: token.refreshToken ?? token.accessToken)
        }
        try tokenStore.delete(account: account)
        for source in coveredSources {
            await status.reportDisconnected(source)
        }
    }

    public func isConnected() async -> Bool {
        (try? tokenStore.load(account: account)) != nil
    }

    // MARK: AccessTokenProviding

    public func validAccessToken() async throws -> String {
        guard let token = try tokenStore.load(account: account) else {
            // Not connected — surface as unavailable so the caller degrades visibly rather
            // than proceeding with no auth.
            let err = AppError.integration(.unavailable(source: .calendar, reason: "Not connected"))
            throw err
        }

        if !token.isExpired(asOf: clock.now) {
            return token.accessToken
        }

        // Silent refresh.
        guard let refreshToken = token.refreshToken else {
            try? tokenStore.delete(account: account)
            await markReconnectRequired()
            throw AppError.integration(.tokenRevoked(source: .calendar))
        }

        do {
            let refreshed = try await service.refresh(refreshToken: refreshToken)
            try tokenStore.save(refreshed, account: account)
            return refreshed.accessToken
        } catch let error as AppError {
            if case .integration(.tokenRevoked) = error {
                // The refresh token is dead — delete it and require a reconnect.
                try? tokenStore.delete(account: account)
                await markReconnectRequired()
            }
            throw error
        }
    }

    // MARK: - Helpers

    private var staleness: TimeInterval { 15 * 60 }

    private func markReconnectRequired() async {
        for source in coveredSources {
            await status.reportDegraded(source, .reconnectRequired(source: source))
        }
    }

    private func revokeOnServer(token: String) async {
        var request = URLRequest(url: config.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(token)".data(using: .utf8)
        _ = try? await transport.send(request)
    }
}
