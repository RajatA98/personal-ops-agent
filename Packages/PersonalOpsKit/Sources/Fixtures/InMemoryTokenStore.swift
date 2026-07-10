import Foundation
import Integrations

/// In-memory `TokenStore` for unit tests and previews. `swift test` on the host can't use the
/// real Keychain, so the token-refresh / degradation logic is exercised against this fake;
/// the real `KeychainTokenStore` roundtrip is verified separately on the simulator.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: OAuthToken]
    /// Set to simulate a Keychain failure for a given account.
    public var failOnLoad = false

    public init(seed: [String: OAuthToken] = [:]) {
        self.storage = seed
    }

    public func load(account: String) throws -> OAuthToken? {
        lock.withLock { storage[account] }
    }

    public func save(_ token: OAuthToken, account: String) throws {
        lock.withLock { storage[account] = token }
    }

    public func delete(account: String) throws {
        lock.withLock { _ = storage.removeValue(forKey: account) }
    }

    /// Test convenience: peek at what's stored without going through `load`.
    public func peek(account: String) -> OAuthToken? {
        lock.withLock { storage[account] }
    }
}
