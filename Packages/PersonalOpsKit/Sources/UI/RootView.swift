import SwiftUI
import SwiftData
import Core
import Data
import Integrations
import Goals
import Agent
import Voice

/// # UI module (shared SwiftUI surface)
///
/// Shared, cross-platform (iOS now, macOS in Phase 7B) SwiftUI views live here so both
/// app targets consume one codebase (LOCKED_DECISIONS #1/#10). Phase 1 stood up a memory
/// browser over the SwiftData store; Phase 2 adds an Integrations/Settings tab showing Google
/// Calendar/Gmail connection status, source freshness, and connect/disconnect. Real product UI
/// (Briefing, Ops Inbox, …) arrives in Phase 3B+.
public struct RootView: View {
    private let integrations: IntegrationsEnvironment
    private let agent: AgentEnvironment
    private let voice: VoiceEnvironment?
    /// Phase 7A: the resolved CloudKit sync state, surfaced in the Integrations tab's sync row.
    private let syncState: CloudKitSyncState

    /// The app injects a composed integrations + agent + voice environment; previews/tests can
    /// pass one too. The agent defaults to `.unavailable()` so callers that don't use reasoning
    /// still work; `voice` defaults to nil (no mic affordance) for previews. `syncState` defaults
    /// to `.off` (single-device) for previews/tests.
    public init(integrations: IntegrationsEnvironment,
                agent: AgentEnvironment = .unavailable(),
                voice: VoiceEnvironment? = nil,
                syncState: CloudKitSyncState = .off) {
        self.integrations = integrations
        self.agent = agent
        self.voice = voice
        self.syncState = syncState
    }

    public var body: some View {
        // Briefing is the first/default tab — the daily loop is the product's front door.
        TabView {
            NavigationStack {
                BriefingView(integrations: integrations)
            }
            .tabItem { Label("Briefing", systemImage: "sun.max") }

            NavigationStack {
                CaptureView(voice: voice)
            }
            .tabItem { Label("Capture", systemImage: "square.and.pencil") }

            NavigationStack {
                WeeklyReviewView(integrations: integrations)
            }
            .tabItem { Label("Review", systemImage: "chart.bar") }

            NavigationStack {
                OpsInboxView(integrations: integrations)
            }
            .tabItem { Label("Inbox", systemImage: "tray.full") }

            NavigationStack {
                GoalsView()
            }
            .tabItem { Label("Goals", systemImage: "target") }

            NavigationStack {
                AskView(agent: agent, integrations: integrations, voice: voice)
            }
            .tabItem { Label("Ask", systemImage: "bubble.left.and.text.bubble.right") }

            NavigationStack {
                MemoryBrowserView()
            }
            .tabItem { Label("Memory", systemImage: "brain") }

            NavigationStack {
                IntegrationsSettingsView(status: integrations.status,
                                         controller: integrations.controller,
                                         syncState: syncState)
            }
            .tabItem { Label("Integrations", systemImage: "link") }
        }
    }
}

#Preview {
    RootView(integrations: .unconfigured())
        .modelContainer(PreviewSupport.seededContainer())
}

/// In-memory, seeded container for SwiftUI previews (never touches disk).
enum PreviewSupport {
    static func seededContainer() -> ModelContainer {
        // Force-try is acceptable in a preview-only helper.
        let container = try! DataStore.makeContainer(inMemory: true)
        _ = try? MemorySampleData.seedIfEmpty(context: ModelContext(container))
        return container
    }
}
