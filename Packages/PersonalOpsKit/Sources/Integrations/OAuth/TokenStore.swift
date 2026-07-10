import Foundation
import Core

/// Where OAuth tokens are persisted. Abstracted behind a protocol so the token-refresh and
/// degradation logic is unit-testable with an in-memory fake (`swift test` on the host can't
/// use the real Keychain), while production uses `KeychainTokenStore`.
///
/// The `account` identifies which integration's token set — a single Google authorization
/// grants Calendar + Gmail together, so there is normally one account (`google`), but the
/// protocol keeps it general.
public protocol TokenStore: Sendable {
    /// Return the stored token for `account`, or `nil` if none is stored.
    func load(account: String) throws -> OAuthToken?
    /// Store (or replace) the token for `account`.
    func save(_ token: OAuthToken, account: String) throws
    /// Remove the token for `account` (used on disconnect / revocation).
    func delete(account: String) throws
}

/// The well-known account identifier for the single Google authorization (Calendar + Gmail).
public enum TokenAccount {
    public static let google = "google"
}
