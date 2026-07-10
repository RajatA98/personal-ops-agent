import Foundation
import CryptoKit

/// Google requires client-supplied event IDs to be base32hex (characters `a`–`v` and
/// `0`–`9`), length 5–1024, and lowercase. A caller's idempotency key is an arbitrary string,
/// so we deterministically derive a valid Google event ID from it: the same key always maps
/// to the same ID, which is what makes a retried create idempotent (a duplicate ID → 409).
public enum GoogleEventID {
    /// Deterministic, RFC 4648 base32hex-lowercase ID derived from `idempotencyKey`.
    public static func make(from idempotencyKey: String) -> String {
        let digest = SHA256.hash(data: Data(idempotencyKey.utf8))
        return "poa" + base32hexLower(Data(digest))
    }

    /// Whether a string is already a valid Google event ID (usable as-is).
    public static func isValid(_ id: String) -> Bool {
        guard (5...1024).contains(id.count) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuv0123456789")
        return id.allSatisfy { allowed.contains($0) }
    }

    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuv")

    static func base32hexLower(_ data: Data) -> String {
        var output = ""
        var buffer: UInt32 = 0
        var bitsInBuffer = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsInBuffer += 8
            while bitsInBuffer >= 5 {
                let index = Int((buffer >> UInt32(bitsInBuffer - 5)) & 0x1F)
                output.append(alphabet[index])
                bitsInBuffer -= 5
            }
        }
        if bitsInBuffer > 0 {
            let index = Int((buffer << UInt32(5 - bitsInBuffer)) & 0x1F)
            output.append(alphabet[index])
        }
        return output
    }
}
