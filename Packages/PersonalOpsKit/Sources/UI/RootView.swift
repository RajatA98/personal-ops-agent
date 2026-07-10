import SwiftUI
import SwiftData
import Core
import Data

/// # UI module (shared SwiftUI surface)
///
/// Shared, cross-platform (iOS now, macOS in Phase 7B) SwiftUI views live here so both
/// app targets consume one codebase (LOCKED_DECISIONS #1/#10). Phase 1 replaces the Phase 0
/// placeholder shell with a real navigation surface over the SwiftData-backed memory store:
/// a browser that makes the append-only / revision / expiry / conflict lifecycle *visible*
/// on seed data. Real product UI (Briefing, Ops Inbox, …) arrives in Phase 3B+.
public struct RootView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            MemoryBrowserView()
        }
    }
}

#Preview {
    RootView()
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
