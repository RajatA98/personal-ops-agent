import SwiftUI
import SwiftData
import Core
import Data
import Goals
import Integrations
import DailyLoop

/// # Weekly Review tab (Phase 3B)
///
/// A per-goal rollup of the week: what got done, what slipped, and what's queued for next week
/// — assembled deterministically by `WeeklyReviewAssembler` (package, unit-tested). Phase 4A
/// turns the "next week" bucket into a batch of `create_agent_calendar_event` Proposals; Phase
/// 5 wraps this same structured value in an LLM narrative.
public struct WeeklyReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var goals: [Goal]

    private let integrations: IntegrationsEnvironment

    @State private var review: WeeklyReview?

    public init(integrations: IntegrationsEnvironment) {
        self.integrations = integrations
    }

    private var activeGoals: [Goal] {
        goals.filter { $0.supersededAt == nil && $0.expiresAt == nil && $0.status == .active }
    }

    public var body: some View {
        List {
            if let review {
                if !review.degradedSources.isEmpty {
                    Section("Degraded sources this week") {
                        ForEach(review.degradedSources) { s in
                            Text(sourceName(s.source)).foregroundStyle(.orange)
                        }
                    }
                }
                if review.goals.isEmpty {
                    ContentUnavailableView("No active goals", systemImage: "calendar",
                                           description: Text("Create a goal to get a weekly rollup."))
                }
                ForEach(review.goals) { rollup in
                    Section(rollup.goalTitle) {
                        bucket("Completed", rollup.completed, systemImage: "checkmark.circle", tint: .green)
                        bucket("Slipped", rollup.slipped, systemImage: "exclamationmark.triangle", tint: .orange)
                        bucket("Next week", rollup.nextWeek, systemImage: "arrow.forward.circle", tint: .blue)
                    }
                }
            } else {
                ContentUnavailableView("Building your review…", systemImage: "chart.bar")
            }
        }
        .navigationTitle("Weekly Review")
        .task { reload() }
        .refreshable { reload() }
    }

    @ViewBuilder
    private func bucket(_ title: String, _ tasks: [BriefingTask],
                        systemImage: String, tint: Color) -> some View {
        if tasks.isEmpty {
            Label("\(title): none", systemImage: systemImage).foregroundStyle(.secondary)
        } else {
            DisclosureGroup {
                ForEach(tasks) { t in
                    Text(t.title).font(.callout)
                }
            } label: {
                Label("\(title): \(tasks.count)", systemImage: systemImage).foregroundStyle(tint)
            }
        }
    }

    private func reload() {
        let degraded = integrations.status.ordered.map(\.freshness)
        review = WeeklyReviewAssembler().assemble(
            now: Date(),
            goals: activeGoals.map { BriefingGoalInput(goal: $0) },
            degradedSources: degraded)
    }

    private func sourceName(_ s: DataSource) -> String {
        switch s {
        case .calendar: return "Calendar"
        case .gmail: return "Gmail"
        case .healthKit: return "HealthKit"
        case .reasoning: return "Reasoning"
        case .iMessage: return "iMessage"
        }
    }
}
