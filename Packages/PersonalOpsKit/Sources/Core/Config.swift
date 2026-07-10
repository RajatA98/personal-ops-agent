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
    /// Phase 7A opt-in: whether to attempt CloudKit iPhone↔Mac sync at launch. **Default OFF.**
    /// Optional key (`CLOUDKIT_SYNC_ENABLED=true`), so existing `Config.local` files without it
    /// keep parsing unchanged. Even when `true`, the container degrades gracefully to local-only
    /// if iCloud/CloudKit is unavailable (see `DataStore.resolve`). Flip this to `true` only after
    /// following `docs/CLOUDKIT_SETUP.md` (needs a paid Apple Developer account + iCloud capability).
    public let cloudKitSyncEnabled: Bool

    public init(googleOAuthClientID: String,
                geminiAPIKey: String,
                elevenLabsAPIKey: String,
                cloudKitSyncEnabled: Bool = false) {
        self.googleOAuthClientID = googleOAuthClientID
        self.geminiAPIKey = geminiAPIKey
        self.elevenLabsAPIKey = elevenLabsAPIKey
        self.cloudKitSyncEnabled = cloudKitSyncEnabled
    }

    public enum Key: String, CaseIterable {
        case googleOAuthClientID = "GOOGLE_OAUTH_CLIENT_ID"
        case geminiAPIKey = "GEMINI_API_KEY"
        case elevenLabsAPIKey = "ELEVENLABS_API_KEY"
        /// Optional (not required to parse); absent ⇒ sync off.
        case cloudKitSyncEnabled = "CLOUDKIT_SYNC_ENABLED"
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

        // Optional boolean flag; absent or non-"true" ⇒ false. Never a parse error (keeps older
        // Config.local files valid).
        let cloudKit = (values[Key.cloudKitSyncEnabled.rawValue]?.lowercased()) == "true"

        return Config(
            googleOAuthClientID: try require(.googleOAuthClientID),
            geminiAPIKey: try require(.geminiAPIKey),
            elevenLabsAPIKey: try require(.elevenLabsAPIKey),
            cloudKitSyncEnabled: cloudKit
        )
    }

    /// All secret values, for registration with `RedactingLogger` at startup so they are
    /// never accidentally logged.
    public var secrets: [String] {
        [googleOAuthClientID, geminiAPIKey, elevenLabsAPIKey]
    }
}
