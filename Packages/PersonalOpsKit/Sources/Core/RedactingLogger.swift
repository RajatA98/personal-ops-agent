import Foundation
import OSLog

/// Local logging wrapper with privacy redaction. Safety Rule #5: secrets are never
/// logged. This is the *only* sanctioned logging entry point — it scrubs bearer tokens,
/// API keys, and emails via patterns, plus any explicitly registered secret value
/// (e.g. keys loaded from `Config`), before anything reaches the unified log.
public struct RedactingLogger: Sendable {

    public enum Level: String, Sendable {
        case debug, info, warning, error
    }

    private let subsystem: String
    private var registeredSecrets: [String]
    private let logger: os.Logger

    public init(subsystem: String = "com.rajatarora.PersonalOpsAgent",
                category: String = "app") {
        self.subsystem = subsystem
        self.registeredSecrets = []
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    /// Register a secret value that must always be scrubbed from log output, regardless
    /// of pattern matching. Call this once for each key loaded from `Config`.
    public mutating func registerSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        registeredSecrets.append(trimmed)
    }

    /// Return `message` with all detectable secrets replaced by `[REDACTED]`.
    public func redact(_ message: String) -> String {
        var out = message

        // 1. Exact registered secrets first (longest first to avoid partial leftovers).
        for secret in registeredSecrets.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: secret, with: Self.token)
        }

        // 2. Known patterns.
        for pattern in Self.patterns {
            out = pattern.replace(in: out)
        }
        return out
    }

    public func log(_ level: Level, _ message: String) {
        let safe = redact(message)
        switch level {
        case .debug: logger.debug("\(safe, privacy: .public)")
        case .info: logger.info("\(safe, privacy: .public)")
        case .warning: logger.warning("\(safe, privacy: .public)")
        case .error: logger.error("\(safe, privacy: .public)")
        }
    }

    // MARK: - Redaction rules

    private static let token = "[REDACTED]"

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let template: String
        func replace(in input: String) -> String {
            let range = NSRange(input.startIndex..., in: input)
            return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
        }
    }

    private static let patterns: [Rule] = {
        func rule(_ pattern: String, _ template: String = token) -> Rule? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return Rule(regex: re, template: template)
        }
        return [
            // Bearer tokens: keep the word "Bearer", scrub the value.
            rule("Bearer\\s+[A-Za-z0-9._~+/=-]+", "Bearer \(token)"),
            // Google API keys (AIza…), OAuth client secrets (GOCSPX-…), refresh/access tokens (ya29.…).
            rule("AIza[0-9A-Za-z._-]{10,}"),
            rule("GOCSPX-[0-9A-Za-z._-]{10,}"),
            rule("ya29\\.[0-9A-Za-z._-]{10,}"),
            // Emails.
            rule("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[REDACTED_EMAIL]")
        ].compactMap { $0 }
    }()
}
