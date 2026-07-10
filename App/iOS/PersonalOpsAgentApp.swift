import SwiftUI
import UI

/// iOS app entry point. Phase 0 renders the shared `RootView` from the `UI` module to
/// prove the app shell builds, runs, and links `PersonalOpsKit`. Phase 1 introduces the
/// SwiftData model container here.
@main
struct PersonalOpsAgentApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
