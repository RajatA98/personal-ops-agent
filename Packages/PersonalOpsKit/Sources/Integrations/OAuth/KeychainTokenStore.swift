import Foundation
import Security
import Core

/// Stores `OAuthToken`s in the iOS/macOS Keychain (LOCKED_DECISIONS #4/#8). The token is
/// JSON-encoded into a single generic-password item keyed by `service` + `account`.
///
/// - Accessibility is `afterFirstUnlock` so silent refresh can run after a device reboot
///   (before the user's first manual unlock the token is unavailable — acceptable).
/// - Nothing here is ever logged (Safety Rule #5): on error we surface a typed
///   `AppError.auth(.keychainFailure)` with only the OSStatus code, never the token bytes.
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let accessibleAfterFirstUnlock: Bool

    /// The Keychain accessibility class, computed on demand (CFString isn't `Sendable`, so
    /// we store the choice as a `Bool` and derive the constant where used).
    private var accessible: CFString {
        accessibleAfterFirstUnlock ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleWhenUnlocked
    }

    public init(service: String = "com.rajatarora.PersonalOpsAgent.oauth",
                accessibleAfterFirstUnlock: Bool = true) {
        self.service = service
        self.accessibleAfterFirstUnlock = accessibleAfterFirstUnlock
    }

    public func load(account: String) throws -> OAuthToken? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(OAuthToken.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.auth(.keychainFailure)
        }
    }

    public func save(_ token: OAuthToken, account: String) throws {
        let data: Data
        do { data = try JSONEncoder().encode(token) }
        catch { throw AppError.auth(.keychainFailure) }

        // Upsert: try update first, insert if the item does not yet exist.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                         attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var insert = baseQuery(account: account)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = accessible
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AppError.auth(.keychainFailure) }
            return
        }
        throw AppError.auth(.keychainFailure)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.auth(.keychainFailure)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
