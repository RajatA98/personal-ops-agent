import Foundation
import Core
import Data

/// # TaskActioner — one-tap complete / skip on a goal task
///
/// The cheapest possible way to log reality: a single tap on a `GoalTask` in the briefing (or
/// the widget) records what happened, so Evening Capture has less to ask about later
/// (PROJECT_PLAN Phase 3B: "every tap here shrinks what Evening Capture has to ask about").
///
/// Both actions write a `GoalProgress` memory fact — the evidence Phase 3A's `SlipDetector`
/// looks for — via the append-only `MemoryStore`. `complete` additionally flips the task's
/// `isComplete`; because the task lives in the same `ModelContext` the store saves through,
/// that mutation is persisted in the same save. The `metricKey` comes from the goal's playbook
/// `progressSignals` (the caller supplies it, since a `GoalTask` does not carry its rule key).
///
/// Not `Sendable` (wraps a `MemoryStore`, which is bound to its context's actor).
public struct TaskActioner {

    private let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    /// Mark a task complete and log completion evidence. Returns the new `GoalProgress`.
    @discardableResult
    public func complete(
        task: GoalTask,
        goal: Goal,
        metricKey: String,
        value: Double = 1,
        note: String = "Completed via one-tap",
        now: Date
    ) throws -> GoalProgress {
        task.isComplete = true
        task.updatedAt = now
        let progress = makeProgress(goal: goal, metricKey: metricKey, value: value,
                                    note: note, now: now, kind: "complete")
        try store.insert(progress)
        return progress
    }

    /// Acknowledge a task as skipped — logs a zero-value progress note (reality captured), but
    /// does **not** mark the task complete. Returns the new `GoalProgress`.
    @discardableResult
    public func skip(
        task: GoalTask,
        goal: Goal,
        metricKey: String,
        note: String = "Skipped via one-tap",
        now: Date
    ) throws -> GoalProgress {
        let progress = makeProgress(goal: goal, metricKey: metricKey, value: 0,
                                    note: note, now: now, kind: "skip")
        try store.insert(progress)
        return progress
    }

    private func makeProgress(
        goal: Goal, metricKey: String, value: Double, note: String, now: Date, kind: String
    ) -> GoalProgress {
        let progress = GoalProgress(
            source: .user,
            createdAt: now,
            updatedAt: now,
            metricKey: metricKey,
            value: value,
            note: note,
            goal: goal)
        // Each progress mark is its own memory fact; make the key unique per mark so entries
        // append rather than being read as revisions of one another.
        progress.factKey = "progress:\(goal.factKey):\(metricKey):\(kind):\(progress.appID.uuidString)"
        return progress
    }
}
