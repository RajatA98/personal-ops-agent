import SwiftUI
import Core

/// # UI module (shared SwiftUI surface)
///
/// Shared, cross-platform (iOS now, macOS in Phase 7B) SwiftUI views live here so both
/// app targets consume one codebase (LOCKED_DECISIONS #1/#10). Phase 0 ships a minimal
/// app shell proving the app builds, runs, and links `PersonalOpsKit`. Phase 1 replaces
/// this with real navigation over the SwiftData store.
public struct RootView: View {
    public init() {}

    private let modules = ["Data", "Integrations", "Goals", "Proposals", "Reasoning", "Voice", "UI"]

    public var body: some View {
        NavigationStack {
            List {
                Section("Personal Ops Agent") {
                    Text("Scaffold ready — Phase 0")
                        .font(.headline)
                    Text("Daily operating layer. Propose, don't auto-act.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("Modules") {
                    ForEach(modules, id: \.self) { module in
                        Label(module, systemImage: "square.stack.3d.up")
                    }
                }
            }
            .navigationTitle("Ops Agent")
        }
    }
}

#Preview {
    RootView()
}
