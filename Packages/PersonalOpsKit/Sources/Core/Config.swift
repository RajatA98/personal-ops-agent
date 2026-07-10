import Foundation

/// Configuration/secrets convention. Reads the three third-party credentials from an
/// untracked local `KEY=VALUE` file (see `Secrets/Config.example`). The file is
/// gitignored and its values never appear in logs or the repo (Safety Rule #5).
///
/// This type only *parses and holds* the values. Where the file lives at runtime is a
/// convention documented in docs/SETUP.md (bundled `Config.local` for dev builds); the
/// keys ultimately move to Keychain for OAuth tokens in Phase 2.
public struct Config: Equatable, Sendable {
    public let googleOAuthClientID: String
    public let geminiAPIKey: String
    public let elevenLabsAPIKey: String

    public init(googleOAuthClientID: String, geminiAPIKey: String, elevenLabsAPIKey: String) {
        self.googleOAuthClientID = googleOAuthClientID
        self.geminiAPIKey = geminiAPIKey
        self.elevenLabsAPIKey = elevenLabsAPIKey
    }

    public enum Key: String, CaseIterable {
        case googleOAuthClientID = "GOOGLE_OAUTH_CLIENT_ID"
        case geminiAPIKey = "GEMINI_API_KEY"
        case elevenLabsAPIKey = "ELEVENLABS_API_KEY"
    }

    /// Load and parse from a file URL.
    public static func load(from url: URL) throws -> Config {
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            throw ConfigError.fileNotFound(url.path)
        }
        return try parse(contents)
    }

    /// Parse `KEY=VALUE` contents. Blank lines and `#` comments are ignored; a line with
    /// no `=` is a `malformedLine`; a missing required key is `missingKey`.
    public static func parse(_ contents: String) throws -> Config {
        var values: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                throw ConfigError.malformedLine(line)
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        func require(_ key: Key) throws -> String {
            guard let v = values[key.rawValue], !v.isEmpty else {
                throw ConfigError.missingKey(key.rawValue)
            }
            return v
        }

        return Config(
            googleOAuthClientID: try require(.googleOAuthClientID),
            geminiAPIKey: try require(.geminiAPIKey),
            elevenLabsAPIKey: try require(.elevenLabsAPIKey)
        )
    }

    /// All secret values, for registration with `RedactingLogger` at startup so they are
    /// never accidentally logged.
    public var secrets: [String] {
        [googleOAuthClientID, geminiAPIKey, elevenLabsAPIKey]
    }
}
