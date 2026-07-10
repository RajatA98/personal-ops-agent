import XCTest
import Core
@testable import Integrations
import Fixtures

final class TokenStoreTests: XCTestCase {

    private func token(access: String = "a") -> OAuthToken {
        OAuthToken(accessToken: access, refreshToken: "r",
                   expiresAt: Date(timeIntervalSince1970: 5000), scope: "s")
    }

    func test_inMemoryStore_roundtrips() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load(account: "google"))
        try store.save(token(access: "first"), account: "google")
        XCTAssertEqual(try store.load(account: "google")?.accessToken, "first")
    }

    func test_inMemoryStore_saveReplaces() throws {
        let store = InMemoryTokenStore()
        try store.save(token(access: "first"), account: "google")
        try store.save(token(access: "second"), account: "google")
        XCTAssertEqual(try store.load(account: "google")?.accessToken, "second")
    }

    func test_inMemoryStore_delete() throws {
        let store = InMemoryTokenStore()
        try store.save(token(), account: "google")
        try store.delete(account: "google")
        XCTAssertNil(try store.load(account: "google"))
    }

    func test_token_codableRoundtrip_preservesFields() throws {
        // The Keychain stores the token as JSON — verify the codable shape survives.
        let original = OAuthToken(accessToken: "acc", refreshToken: "ref",
                                  expiresAt: Date(timeIntervalSince1970: 1234),
                                  scope: "cal gmail", tokenType: "Bearer")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OAuthToken.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
