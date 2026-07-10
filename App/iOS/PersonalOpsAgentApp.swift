import SwiftUI
import SwiftData
import Core
import Data
import Integrations
import Signals
import Agent
import Reasoning
import Voice
import UI

/// iOS app entry point. Phase 1 stands up the SwiftData model container; Phase 2 composes the
/// Google integrations environment (OAuth authenticator, Calendar/Gmail clients, status store)
/// and injects it into the shared `RootView`, which now has an Integrations/Settings tab.
///
/// Secrets: if `Secrets/Config.local` is bundled, its values are registered with the redacting
/// logger (Safety Rule #5) and the live OAuth client ID is used. If it is absent (the default
/// checked-out state — the file is gitignored), the app still runs fully: the Integrations
/// screen shows everything disconnected and Connect surfaces a clear "add your Google client
/// ID" message rather than crashing.
@main
struct PersonalOpsAgentApp: App {
    private let container: ModelContainer
    private let syncState: CloudKitSyncState
    private let integrations: IntegrationsEnvironment
    private let agent: AgentEnvironment
    private let voice: VoiceEnvironment

    init() {
        // Load local secrets FIRST — the CloudKit opt-in (`CLOUDKIT_SYNC_ENABLED`, default OFF) must
        // be known before the container is built. Absent config ⇒ sync off, app runs local-only.
        let localConfig = Self.loadLocalConfig()

        // Phase 7A: resolve the container with graceful CloudKit degradation. When the flag is on we
        // attach the CloudKit private database; if iCloud/CloudKit is unavailable (simulator / free
        // Apple ID) `resolve` falls back to a fully-working local-only store and reports why — it
        // never crashes. When the flag is off it's a plain local-only container (`.off`).
        do {
            let resolved = try DataStore.resolve(preferCloudKit: localConfig?.cloudKitSyncEnabled ?? false)
            try MemorySampleData.seedIfEmpty(context: ModelContext(resolved.container))
            self.container = resolved.container
            self.syncState = resolved.syncState
        } catch {
            fatalError("Failed to initialize the model container: \(error)")
        }
        let container = self.container

        // Register secrets for log redaction before anything runs.
        var logger = RedactingLogger()
        if let config = localConfig {
            for secret in config.secrets { logger.registerSecret(secret) }
            // Durable Gmail metadata store (Phase 4B) so scan dedupe survives relaunch.
            self.integrations = .live(clientID: config.googleOAuthClientID,
                                      metadataStore: SwiftDataGmailMetadataStore(modelContainer: container))
            // Reasoning layer (Phase 5): Gemini Flash if a real key is present, else unavailable.
            if Self.isRealKey(config.geminiAPIKey) {
                self.agent = .live(apiKey: config.geminiAPIKey,
                                   audit: LoggingModelCallAuditSink(logger: logger))
                logger.log(.info, "Reasoning layer configured (Gemini Flash).")
            } else {
                self.agent = .unavailable()
                logger.log(.info, "No Gemini API key — reasoning layer unavailable.")
            }
            // Voice layer (Phase 6): ElevenLabs TTS when a real key is present, else the system
            // voice; on-device STT (Apple Speech) either way.
            self.voice = .live(elevenLabsAPIKey: config.elevenLabsAPIKey)
            logger.log(.info, Self.isRealKey(config.elevenLabsAPIKey)
                       ? "Voice configured (ElevenLabs TTS)."
                       : "Voice configured (system voice — no ElevenLabs key).")
            logger.log(.info, "Integrations configured for Google OAuth client.")
        } else {
            self.integrations = .unconfigured()
            self.agent = .unavailable()
            self.voice = .live(elevenLabsAPIKey: nil)
            logger.log(.info, "No Secrets/Config.local found — integrations start unconfigured.")
        }

        // Phase 7A: record how CloudKit sync resolved (off / on / degraded). Never logs secrets.
        switch syncState {
        case .off: logger.log(.info, "iCloud sync off (local-only).")
        case .active: logger.log(.info, "iCloud sync enabled (CloudKit private database attached).")
        case .unavailable(let reason): logger.log(.info, "iCloud sync requested but unavailable — \(reason)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(integrations: integrations, agent: agent, voice: voice, syncState: syncState)
        }
        .modelContainer(container)
    }

    /// A key is "real" only if present and not the template placeholder — so a checked-out
    /// `Config.example`-shaped file doesn't try to talk to Gemini with `REPLACE_ME`.
    private static func isRealKey(_ key: String) -> Bool {
        !key.isEmpty && !key.hasPrefix("REPLACE_ME")
    }

    /// Look for a bundled `Config.local` (dev builds copy it into the app bundle). Returns
    /// `nil` if absent or malformed — the app degrades to the unconfigured environment.
    private static func loadLocalConfig() -> Config? {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "local") else {
            return nil
        }
        return try? Config.load(from: url)
    }
}
