import SwiftUI
import SwiftData
import Core
import Data
import Integrations
import Signals
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
    private let integrations: IntegrationsEnvironment

    init() {
        do {
            let container = try DataStore.makeContainer()
            try MemorySampleData.seedIfEmpty(context: ModelContext(container))
            self.container = container
        } catch {
            fatalError("Failed to initialize the model container: \(error)")
        }

        // Load local secrets if present; register them for log redaction before anything runs.
        var logger = RedactingLogger()
        if let config = Self.loadLocalConfig() {
            for secret in config.secrets { logger.registerSecret(secret) }
            // Durable Gmail metadata store (Phase 4B) so scan dedupe survives relaunch.
            self.integrations = .live(clientID: config.googleOAuthClientID,
                                      metadataStore: SwiftDataGmailMetadataStore(modelContainer: container))
            logger.log(.info, "Integrations configured for Google OAuth client.")
        } else {
            self.integrations = .unconfigured()
            logger.log(.info, "No Secrets/Config.local found — integrations start unconfigured.")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(integrations: integrations)
        }
        .modelContainer(container)
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
