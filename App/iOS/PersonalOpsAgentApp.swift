import SwiftUI
import SwiftData
import Core
import Data
import UI

/// iOS app entry point. Phase 1 stands up the SwiftData model container (built from the
/// versioned, CloudKit-compatible schema via `DataStore`) and injects it into the shared
/// `RootView`. On first launch the store is seeded with illustrative memory facts so the
/// memory browser has something real to show. CloudKit sync stays off until Phase 7A —
/// the schema is CloudKit-*compatible* now, but sync is a later, separately-hardened phase.
@main
struct PersonalOpsAgentApp: App {
    private let container: ModelContainer

    init() {
        do {
            let container = try DataStore.makeContainer()
            try MemorySampleData.seedIfEmpty(context: ModelContext(container))
            self.container = container
        } catch {
            // A failed store is not recoverable at launch; fail loudly rather than run
            // against a phantom store (Phase 7A revisits recovery/migration UX).
            fatalError("Failed to initialize the model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
