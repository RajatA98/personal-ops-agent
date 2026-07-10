import Foundation
import CryptoKit

/// PKCE (Proof Key for Code Exchange, RFC 7636) parameters for the native-app OAuth flow.
///
/// A native app has **no client secret** (it can't keep one secret on-device), so Google's
/// OAuth for installed apps uses PKCE instead: the app generates a random `codeVerifier`,
/// sends its SHA-256 hash (`codeChallenge`) on the authorization request, and later proves
/// possession by sending the original verifier on the token exchange. This binds the
/// authorization code to this specific app instance, so an intercepted code is useless
/// without the verifier.
public struct PKCE: Equatable, Sendable {
    /// The high-entropy random string kept in memory until the token exchange.
    public let codeVerifier: String
    /// `BASE64URL(SHA256(codeVerifier))` — sent on the authorization request.
    public let codeChallenge: String
    /// The challenge method. We always use `S256` (never plain).
    public let method = "S256"

    public init(codeVerifier: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = Self.challenge(for: codeVerifier)
    }

    /// Generate a fresh PKCE pair with a cryptographically random verifier.
    public static func generate() -> PKCE {
        PKCE(codeVerifier: randomVerifier())
    }

    /// Deterministic S256 challenge for a given verifier (pure — testable without randomness).
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    /// A 43–128 char unreserved-charset verifier (RFC 7636 §4.1). We use base64url of 32
    /// random bytes → 43 chars, all in the allowed `[A-Za-z0-9-._~]` set.
    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// Base64URL without padding (RFC 4648 §5) — the encoding OAuth/PKCE requires.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
