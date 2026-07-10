import Foundation
import Core
import Data
import Goals

// MARK: - Structured, serializable weekly review
//
// Like the Morning Briefing, the Weekly Review is a deterministically-assembled, fully
// `Codable` value — the same structure Phase 5 hands to the LLM for a narrative, and the same
// rollup Phase 4A turns into a *batch* of next-week `create_agent_calendar_event` Proposals.

/// One goal's rollup for the week: what got done, what slipped, and what's queued next week.
public struct WeeklyGoalRollup: Codable, Equatable, Sendable, Identifiable {
    public let goalID: UUID
    public let goalTitle: String
    public let completed: [BriefingTask]
    public let slipped: [BriefingTask]
    public let nextWeek: [BriefingTask]

    public var id: UUID { goalID }

    public init(goalID: UUID, goalTitle: String,
                completed: [BriefingTask], slipped: [BriefingTask], nextWeek: [BriefingTask]) {
        self.goalID = goalID
        self.goalTitle = goalTitle
        self.completed = completed
        self.slipped = slipped
        self.nextWeek = nextWeek
    }
}

/// The full weekly review: per-goal rollups plus an honest note of any sources that were
/// degraded during the week (PRD: "generated on the configured day even if some data sources
/// were degraded that week, with degraded sources explicitly noted").
public struct WeeklyReview: Codable, Equatable, Sendable {
    public let weekStart: Date
    public let weekEnd: Date
    public let goals: [WeeklyGoalRollup]
    public let degradedSources: [SourceFreshnessSnapshot]

    public init(weekStart: Date, weekEnd: Date,
                goals: [WeeklyGoalRollup], degradedSources: [SourceFreshnessSnapshot]) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.goals = goals
        self.degradedSources = degradedSources
    }
}

/// # WeeklyReviewAssembler — deterministic per-goal week rollup
///
/// Categorizes each active goal's tasks into completed / slipped / next-week over a
/// seven-day review window ending at `now`. Slip detection is delegated to Phase 3A's
/// `SlipDetector`; completion and next-week bucketing are pure window arithmetic. LLM-free.
public struct WeeklyReviewAssembler {

    private let slipDetector = SlipDetector()

    public init() {}

    /// Assemble the review.
    ///
    /// - Parameters:
    ///   - now: end of the review window (the review runs "as of" this instant).
    ///   - goals: each active goal's task/progress state.
    ///   - degradedSources: freshness for any source that was degraded during the week; only
    ///     the ones actually degraded as of `now` are carried into the review.
    ///   - weekLength: length of the look-back / look-ahead window (default 7 days).
    public func assemble(
        now: Date,
        goals: [BriefingGoalInput],
        degradedSources: [SourceFreshness] = [],
        weekLength: TimeInterval = 7 * 86_400
    ) -> WeeklyReview {
        let weekStart = now.addingTimeInterval(-weekLength)
        let nextWeekEnd = now.addingTimeInterval(weekLength)
        let pastWeek = weekStart...now
        let comingWeek = now...nextWeekEnd

        let rollups = goals.map { goal -> WeeklyGoalRollup in
            let completed = goal.tasks
                .filter { $0.isComplete && windowStart($0).map(pastWeek.contains) == true }
                .map { Self.task(from: $0, goal: goal) }

            let slipped = slipDetector.slippedTasks(
                    tasks: goal.tasks, progress: goal.progress, rule: goal.slipRule, asOf: now)
                .map { Self.task(from: $0, goal: goal) }

            let nextWeek = goal.tasks
                .filter { !$0.isComplete }
                .filter { windowStart($0).map(comingWeek.contains) == true }
                .map { Self.task(from: $0, goal: goal) }
                .sorted { ($0.earliestAcceptable ?? .distantFuture) < ($1.earliestAcceptable ?? .distantFuture) }

            return WeeklyGoalRollup(
                goalID: goal.goalID, goalTitle: goal.goalTitle,
                completed: completed, slipped: slipped, nextWeek: nextWeek)
        }

        let degraded = degradedSources
            .filter { $0.isDegraded(asOf: now) }
            .map { SourceFreshnessSnapshot(freshness: $0, asOf: now) }

        return WeeklyReview(
            weekStart: weekStart, weekEnd: now, goals: rollups, degradedSources: degraded)
    }

    private func windowStart(_ task: GoalTask) -> Date? {
        task.earliestAcceptable ?? task.latestAcceptable
    }

    private static func task(from task: GoalTask, goal: BriefingGoalInput) -> BriefingTask {
        BriefingTask(
            taskID: task.appID, goalID: goal.goalID, goalTitle: goal.goalTitle,
            title: task.title, flexibility: task.flexibility, priority: task.priority,
            earliestAcceptable: task.earliestAcceptable, latestAcceptable: task.latestAcceptable,
            isComplete: task.isComplete)
    }
}
