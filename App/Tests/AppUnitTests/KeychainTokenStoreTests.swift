import XCTest
import Core
@testable import Integrations

/// Exercises the REAL `KeychainTokenStore` against the device/simulator Keychain (the package
/// `swift test` suite can't reach the Keychain, so it uses `InMemoryTokenStore`; this app-
/// hosted target runs on the simulator where the Keychain is available).
///
/// Some simulator/CI configurations deny Keychain access to an unsigned test host
/// (`errSecMissingEntitlement`). Rather than fail the suite for an environment constraint, we
/// `XCTSkip` in that case — on a normally-signed build (device or a signed simulator run) the
/// full roundtrip is verified.
final class KeychainTokenStoreTests: XCTestCase {

    private let account = "test-account"
    private let service = "com.rajatarora.PersonalOpsAgent.oauth.tests"

    private func makeStore() -> KeychainTokenStore { KeychainTokenStore(service: service) }

    override func tearDown() {
        try? makeStore().delete(account: account)
        super.tearDown()
    }

    private func sampleToken(access: String = "acc") -> OAuthToken {
        OAuthToken(accessToken: access, refreshToken: "ref",
                   expiresAt: Date(timeIntervalSince1970: 5000), scope: "cal gmail")
    }

    func test_realKeychain_roundtrips() throws {
        let store = makeStore()
        do {
            try store.save(sampleToken(access: "first"), account: account)
        } catch AppError.auth(.keychainFailure) {
            throw XCTSkip("Keychain unavailable in this test environment (unsigned host).")
        }
        let loaded = try store.load(account: account)
        XCTAssertEqual(loaded?.accessToken, "first")
        XCTAssertEqual(loaded?.refreshToken, "ref")
    }

    func test_realKeychain_saveReplacesAndDeletes() throws {
        let store = makeStore()
        do {
            try store.save(sampleToken(access: "first"), account: account)
        } catch AppError.auth(.keychainFailure) {
            throw XCTSkip("Keychain unavailable in this test environment (unsigned host).")
        }
        try store.save(sampleToken(access: "second"), account: account)
        XCTAssertEqual(try store.load(account: account)?.accessToken, "second")

        try store.delete(account: account)
        XCTAssertNil(try store.load(account: account))
    }
}
