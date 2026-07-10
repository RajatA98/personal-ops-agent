import Foundation
import Core
import Data

/// # SlipDetector — deterministic, LLM-free slip detection
///
/// Given a goal's tasks, its logged progress, and a date (from an injected `Clock`), flags
/// the tasks that have *slipped*: past their acceptable window with no evidence they
/// happened. This is the signal the Morning Briefing (Phase 3B) surfaces and the
/// `modify_goal_plan` Proposal (Phase 4A) can act on.
///
/// A task counts as slipped when **all** of these hold, per the playbook's `SlipRule`:
///   • it is not marked complete, and
///   • `asOf` is later than `latestAcceptable + gracePeriod`, and
///   • if the rule requires completion evidence, no `GoalProgress` entry falls within the
///     task's window (earliest … deadline).
///
/// Tasks with no `latestAcceptable` (open-ended) cannot slip — there is no deadline to miss.
public struct SlipDetector: Sendable {

    public init() {}

    /// Return the slipped tasks (a subset of `tasks`), preserving input order.
    public func slippedTasks(
        tasks: [GoalTask],
        progress: [GoalProgress],
        rule: SlipRule,
        asOf: Date
    ) -> [GoalTask] {
        tasks.filter { isSlipped(task: $0, progress: progress, rule: rule, asOf: asOf) }
    }

    /// Whether one task has slipped as of `asOf`.
    public func isSlipped(
        task: GoalTask,
        progress: [GoalProgress],
        rule: SlipRule,
        asOf: Date
    ) -> Bool {
        guard !task.isComplete else { return false }
        guard let latest = task.latestAcceptable else { return false }

        let deadline = latest.addingTimeInterval(rule.gracePeriod)
        guard asOf > deadline else { return false }

        if rule.requiresCompletionEvidence {
            let windowStart = task.earliestAcceptable ?? .distantPast
            let hasEvidence = progress.contains { entry in
                entry.createdAt >= windowStart && entry.createdAt <= deadline
            }
            if hasEvidence { return false }
        }

        return true
    }
}
