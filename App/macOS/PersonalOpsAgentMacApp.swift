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

/// # macOS app entry point (Phase 7B)
///
/// The Mac companion (LOCKED_DECISIONS #1/#10) shares the *entire* SwiftUI surface and business
/// logic with iOS — it composes the same four environments (`DataStore.resolve`,
/// `IntegrationsEnvironment`, `AgentEnvironment`, `VoiceEnvironment`) and renders the same shared
/// `RootView`. The only platform differences, all handled here:
///
///   • **HealthKit → synced data.** macOS has no HealthKit framework. Per Phase 3C's `\.healthKitSource`
///     seam, the Mac injects a `SyncedHealthSummaryStore` (reads the `HealthSummaryRecord`s the
///     iPhone mirrored + CloudKit synced) instead of `HealthKitClient`. The pure `PacedPlanner`
///     runs off synced summaries; the Mac never reads HealthKit natively. With sync off (or no
///     data yet) it simply returns no summaries and the pacing UI honestly shows "no pacing".
///
///   • **Google OAuth → per-device authorization.** `IntegrationsEnvironment.live` uses
///     `ASWebAuthenticationSession` (works on macOS) with tokens in the Mac Keychain. We
///     deliberately authorize *per device* (the simpler, safer default) rather than syncing tokens
///     via iCloud Keychain — so the user connects Google once on the Mac too. See docs/MAC_SETUP.md.
///
///   • **Container.** Built via the same `DataStore.resolve(preferCloudKit:)` and CloudKit container
///     ID as iOS (Phase 7A handoff #1), so both platforms mirror one private database. The Mac app
///     is pointless without sync, which requires the paid Apple Developer Program — see
///     docs/CLOUDKIT_SETUP.md. With sync off the Mac runs fully local-only, single-device.
///
///   • **No widget, no iMessage/Shortcuts intent.** The WidgetKit extension stays iOS-only
///     (macOS widgets are future work). The "When I get a message" Shortcuts automation is not
///     available on macOS the way it is on iOS; the shared `ShortcutIntakeService`/`PlanTextExtractor`
///     core is platform-neutral and a Mac entry wrapper is documented as future work (docs/MAC_SETUP.md).
@main
struct PersonalOpsAgentMacApp: App {
    private let container: ModelContainer
    private let syncState: CloudKitSyncState
    private let integrations: IntegrationsEnvironment
    private let agent: AgentEnvironment
    private let voice: VoiceEnvironment
    /// The Mac's HealthKit seam: reads synced `HealthSummaryRecord`s (no native HealthKit).
    private let healthSource: any HealthKitDataSource

    init() {
        // Load local secrets FIRST — the CloudKit opt-in must be known before the container is built.
        let localConfig = Self.loadLocalConfig()

        // Same resolution path as iOS (Phase 7A): CloudKit if requested, graceful local-only fallback.
        do {
            let resolved = try DataStore.resolve(preferCloudKit: localConfig?.cloudKitSyncEnabled ?? false)
            try MemorySampleData.seedIfEmpty(context: ModelContext(resolved.container))
            self.container = resolved.container
            self.syncState = resolved.syncState
        } catch {
            fatalError("Failed to initialize the model container: \(error)")
        }
        let container = self.container

        // The Mac reads HealthKit-derived pacing as SYNCED data (Phase 3C/7A handoff) — never natively.
        self.healthSource = SyncedHealthSummaryStore(modelContainer: container)

        var logger = RedactingLogger()
        if let config = localConfig {
            for secret in config.secrets { logger.registerSecret(secret) }
            // Durable Gmail metadata store so scan dedupe survives relaunch (shared with iOS via sync).
            self.integrations = .live(clientID: config.googleOAuthClientID,
                                      metadataStore: SwiftDataGmailMetadataStore(modelContainer: container))
            if Self.isRealKey(config.geminiAPIKey) {
                self.agent = .live(apiKey: config.geminiAPIKey,
                                   audit: LoggingModelCallAuditSink(logger: logger))
                logger.log(.info, "Reasoning layer configured (Gemini Flash).")
            } else {
                self.agent = .unavailable()
                logger.log(.info, "No Gemini API key — reasoning layer unavailable.")
            }
            // Voice: STT (Apple Speech) + TTS (ElevenLabs when keyed, else system voice). Both
            // platform-agnostic; the audio session degrades to a no-op host coordinator off-iOS.
            self.voice = .live(elevenLabsAPIKey: config.elevenLabsAPIKey)
            logger.log(.info, Self.isRealKey(config.elevenLabsAPIKey)
                       ? "Voice configured (ElevenLabs TTS)."
                       : "Voice configured (system voice — no ElevenLabs key).")
            logger.log(.info, "Integrations configured for Google OAuth client (per-device authorization).")
        } else {
            self.integrations = .unconfigured()
            self.agent = .unavailable()
            self.voice = .live(elevenLabsAPIKey: nil)
            logger.log(.info, "No Secrets/Config.local found — integrations start unconfigured.")
        }

        switch syncState {
        case .off: logger.log(.info, "iCloud sync off (local-only). Mac companion needs sync for iPhone↔Mac data.")
        case .active: logger.log(.info, "iCloud sync enabled (CloudKit private database attached).")
        case .unavailable(let reason): logger.log(.info, "iCloud sync requested but unavailable — \(reason)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(integrations: integrations, agent: agent, voice: voice, syncState: syncState)
                // Mac HealthKit seam: the synced-data adapter (Phase 3C's EnvironmentKey).
                .environment(\.healthKitSource, healthSource)
        }
        .modelContainer(container)
    }

    private static func isRealKey(_ key: String) -> Bool {
        !key.isEmpty && !key.hasPrefix("REPLACE_ME")
    }

    private static func loadLocalConfig() -> Config? {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "local") else {
            return nil
        }
        return try? Config.load(from: url)
    }
}
