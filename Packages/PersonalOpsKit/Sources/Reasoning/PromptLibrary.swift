import Foundation

/// Loads the versioned prompt files bundled with this module (`Prompts/*.v1.txt`,
/// AGENT_DESIGN §5 — "prompts are code"). Each file's first line is a `PROMPT_VERSION:` header
/// that is parsed off and exposed separately, so the version can be audited/logged while the
/// body is what goes to the model. Prompts contain NO provider-specific syntax — message
/// formatting is the `ReasoningProvider`'s job — so the same prompts serve any provider.
public enum PromptLibrary {

    public enum Prompt: String, CaseIterable {
        case sharedPreamble = "shared-preamble.v1"
        case morningBriefing = "morning-briefing.v1"
        case weeklyReview = "weekly-review.v1"
        case qaSystem = "qa-system.v1"
    }

    public struct LoadedPrompt: Equatable, Sendable {
        /// The parsed `PROMPT_VERSION:` value (e.g. `morning-briefing.v1`), or the file name.
        public let version: String
        /// The prompt body with the version header line removed.
        public let body: String
    }

    /// Load a prompt from the module bundle. Traps only if a shipped resource is missing, which
    /// is a build/packaging error (the files are checked into the target's `Prompts/` folder).
    public static func load(_ prompt: Prompt) -> LoadedPrompt {
        guard let url = Bundle.module.url(forResource: prompt.rawValue, withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Missing bundled prompt resource: \(prompt.rawValue).txt")
        }
        return parse(raw, fallbackVersion: prompt.rawValue)
    }

    static func parse(_ raw: String, fallbackVersion: String) -> LoadedPrompt {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var version = fallbackVersion
        if let first = lines.first,
           first.hasPrefix("PROMPT_VERSION:") {
            version = first
                .dropFirst("PROMPT_VERSION:".count)
                .trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            // Drop a single blank separator line after the header, if present.
            if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return LoadedPrompt(version: version, body: body)
    }
}
