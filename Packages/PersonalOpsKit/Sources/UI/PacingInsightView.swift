import SwiftUI
import Core
import Goals
import Integrations

/// # Pacing insight (Phase 3C UI)
///
/// A self-contained section for the **Goals** detail screen that (a) shows the user's HealthKit
/// pacing toggle and (b) when influence is active, renders the **"HealthKit-influenced"** label
/// with a plain-language, non-medical rationale. This is the visible-labeling requirement
/// (PRD "HealthKit": *"Pacing suggestions influenced by HealthKit data are visibly labeled as
/// such"*).
///
/// It touches no `RootView` and no goal data: the toggle is a per-user preference
/// (`@AppStorage`), and disabling it simply stops asking the coordinator for influence — the
/// goal and its plan are untouched. A denied/absent HealthKit permission surfaces as "no
/// pacing right now", never an error (denial-safe by construction in the coordinator).
public struct PacingInsightView: View {
    private let playbook: GoalPlaybook

    @Environment(\.healthKitSource) private var source
    /// The user-facing toggle to disable HealthKit influence **without** disabling the goal.
    @AppStorage("healthkit_influence_enabled") private var influenceEnabled = true
    @State private var summary: PacingInfluenceSummary?

    public init(playbook: GoalPlaybook) {
        self.playbook = playbook
    }

    public var body: some View {
        Section {
            Toggle("Let HealthKit pace this plan", isOn: $influenceEnabled)

            if !influenceEnabled {
                Text("HealthKit influence is off. Your goal and its plan are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let summary {
                influenceBadge(summary)
            } else {
                Text("No HealthKit pacing right now — recent recovery looks fine, or no Health data is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Pacing")
        } footer: {
            Text("Eases upcoming training load when your recent sleep and recovery have been low. This is pacing guidance, not medical advice.")
        }
        .task(id: influenceEnabled) { await reload() }
    }

    /// The visible "HealthKit-influenced" marker + why.
    @ViewBuilder
    private func influenceBadge(_ summary: PacingInfluenceSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summary.label, systemImage: "heart.text.square.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.pink)
            Text(summary.influence.headline).font(.callout)
            Text(summary.signal.rationale.prefix(1).capitalized + summary.signal.rationale.dropFirst() + ".")
                .font(.caption).foregroundStyle(.secondary)
            if !summary.affectedTitles.isEmpty {
                Text("Eased: " + summary.affectedTitles.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        guard influenceEnabled else { summary = nil; return }
        let coordinator = HealthPacingCoordinator(source: source)
        summary = await coordinator.currentInfluence(
            playbook: playbook, asOf: Date(), influenceEnabled: true)
    }
}

// MARK: - Health source injection (no RootView change required)

private struct HealthKitSourceKey: EnvironmentKey {
    /// The real device reader by default. On the simulator / without Health data it returns no
    /// summaries, so the UI honestly shows "no pacing right now" rather than fabricated influence.
    /// Previews and tests inject a fake via `.environment(\.healthKitSource, …)`.
    static let defaultValue: any HealthKitDataSource = HealthKitClient()
}

public extension EnvironmentValues {
    /// The HealthKit-backed source the pacing UI reads from. Inject a fake for previews/tests;
    /// the app can inject a shared instance at the scene root.
    var healthKitSource: any HealthKitDataSource {
        get { self[HealthKitSourceKey.self] }
        set { self[HealthKitSourceKey.self] = newValue }
    }
}
