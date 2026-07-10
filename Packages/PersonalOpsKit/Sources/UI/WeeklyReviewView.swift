import SwiftUI
import SwiftData
import Core
import Data
import Goals
import Integrations
import DailyLoop
import Proposals

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
    @State private var planning = false
    @State private var planSummary: String?
    @State private var planError: String?

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
                planNextWeekSection(review)
            } else {
                ContentUnavailableView("Building your review…", systemImage: "chart.bar")
            }
        }
        .navigationTitle("Weekly Review")
        .task { reload() }
        .refreshable { reload() }
    }

    /// # "Plan next week" — route the next-week bucket into the Ops Inbox (Phase 4A wiring)
    ///
    /// Turns every goal's `nextWeek` tasks into a batch of pending create-event proposals via
    /// `PlanProposalCoordinator`, so one Sunday session plans the week from the Ops Inbox. Nothing
    /// is written to a calendar until each is approved there (Safety Rule #1).
    @ViewBuilder
    private func planNextWeekSection(_ review: WeeklyReview) -> some View {
        let hasNextWeek = review.goals.contains { !$0.nextWeek.isEmpty }
        if hasNextWeek {
            Section {
                Button {
                    planNextWeek(review)
                } label: {
                    HStack {
                        Label("Plan next week to Ops Inbox", systemImage: "tray.and.arrow.down")
                        if planning { Spacer(); ProgressView() }
                    }
                }
                .disabled(planning)
                if let planSummary {
                    Text(planSummary).font(.caption).foregroundStyle(.secondary)
                }
                if let planError {
                    Label(planError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Adds next week's blocks to your Ops Inbox as proposals to review. Nothing is written to a calendar until you approve it.")
            }
        }
    }

    private func planNextWeek(_ review: WeeklyReview) {
        planning = true
        planError = nil
        planSummary = nil
        defer { planning = false }
        let coordinator = PlanProposalCoordinator(context: modelContext, calendar: integrations.calendar)
        do {
            let count = try coordinator.planNextWeek(from: review)
            planSummary = count == 0
                ? "Nothing new to plan — next week's blocks are already in your Ops Inbox."
                : "Added \(count) proposal(s) for next week to your Ops Inbox."
        } catch let error as AppError {
            planError = error.userMessage
        } catch {
            planError = "Couldn't plan next week right now. Please try again."
        }
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
