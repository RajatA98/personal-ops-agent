import Foundation
import Core
import Data

// MARK: - Capture input (a scripted text/tap interaction, not a form)

/// A completion/skip of a specific task, with the metric to log against it.
public struct TaskOutcome {
    public let task: GoalTask
    public let goal: Goal
    public let metricKey: String
    public let value: Double
    public init(task: GoalTask, goal: Goal, metricKey: String, value: Double = 1) {
        self.task = task
        self.goal = goal
        self.metricKey = metricKey
        self.value = value
    }
}

/// A free-standing progress mark (not tied to completing a specific task) — e.g. "logged 8km
/// run". `metricKey` comes from the goal's playbook `progressSignals`.
public struct ProgressMark {
    public let goal: Goal
    public let metricKey: String
    public let value: Double
    public let note: String
    public init(goal: Goal, metricKey: String, value: Double, note: String = "") {
        self.goal = goal
        self.metricKey = metricKey
        self.value = value
        self.note = note
    }
}

/// A new open loop to remember ("waiting to hear back from the recruiter").
public struct OpenLoopDraft {
    public let title: String
    public let detail: String
    public init(title: String, detail: String = "") {
        self.title = title
        self.detail = detail
    }
}

/// Everything a single Evening Capture interaction can record. All fields optional/empty so a
/// one-tap capture (just marking a task done) is as valid as a full one.
public struct CaptureInput {
    /// Free-text note → becomes today's `DailyLog` summary.
    public var note: String?
    /// Tasks marked complete (flip `isComplete` + log evidence).
    public var completed: [TaskOutcome]
    /// Tasks acknowledged as skipped (log a zero note, no completion).
    public var skipped: [TaskOutcome]
    /// Standalone progress marks.
    public var progressMarks: [ProgressMark]
    /// New open loops to remember.
    public var openLoops: [OpenLoopDraft]

    public init(note: String? = nil,
                completed: [TaskOutcome] = [],
                skipped: [TaskOutcome] = [],
                progressMarks: [ProgressMark] = [],
                openLoops: [OpenLoopDraft] = []) {
        self.note = note
        self.completed = completed
        self.skipped = skipped
        self.progressMarks = progressMarks
        self.openLoops = openLoops
    }
}

/// What a capture wrote — returned for UI confirmation and assertion.
public struct CaptureResult: Equatable, Sendable {
    public let dailyLogWritten: Bool
    public let completedCount: Int
    public let skippedCount: Int
    public let progressCount: Int
    public let openLoopCount: Int
}

/// # EveningCapture — fast text/tap capture that updates memory
///
/// The evening half of the daily loop (voice arrives in Phase 6). It reconciles what actually
/// happened against the day's plan and writes it through the append-only `MemoryStore`:
///   • the note → a `DailyLog` for today (corrected in place if one already exists — so a
///     second capture the same evening revises, never duplicates);
///   • completed/skipped tasks → `GoalProgress` (via `TaskActioner`), completions also flip
///     `GoalTask.isComplete`;
///   • standalone progress marks → `GoalProgress`;
///   • new open loops → `OpenLoop`.
///
/// Deterministic and LLM-free: extraction/narrative is Phase 5/6. Not `Sendable`.
public struct EveningCapture {

    private let store: MemoryStore
    private let calendar: Calendar

    /// - Parameter calendar: used to derive today's stable `DailyLog` fact key; inject a
    ///   fixed-timezone calendar in tests. Defaults to `.current`.
    public init(store: MemoryStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    @discardableResult
    public func apply(_ input: CaptureInput, now: Date) throws -> CaptureResult {
        let actioner = TaskActioner(store: store)

        // 1. Completions & skips (each writes a GoalProgress; completions flip isComplete).
        for outcome in input.completed {
            try actioner.complete(task: outcome.task, goal: outcome.goal,
                                  metricKey: outcome.metricKey, value: outcome.value, now: now)
        }
        for outcome in input.skipped {
            try actioner.skip(task: outcome.task, goal: outcome.goal,
                              metricKey: outcome.metricKey, now: now)
        }

        // 2. Standalone progress marks.
        for mark in input.progressMarks {
            let progress = GoalProgress(
                source: .user, createdAt: now, updatedAt: now,
                metricKey: mark.metricKey, value: mark.value, note: mark.note, goal: mark.goal)
            progress.factKey =
                "progress:\(mark.goal.factKey):\(mark.metricKey):mark:\(progress.appID.uuidString)"
            try store.insert(progress)
        }

        // 3. New open loops.
        for draft in input.openLoops {
            let loop = OpenLoop(
                source: .user, createdAt: now, updatedAt: now,
                title: draft.title, detail: draft.detail)
            loop.factKey = "open_loop:\(loop.appID.uuidString)"
            try store.insert(loop)
        }

        // 4. Today's DailyLog (write once, correct on a repeat capture the same day).
        var dailyLogWritten = false
        if let note = input.note {
            try writeDailyLog(summary: note, now: now)
            dailyLogWritten = true
        }

        return CaptureResult(
            dailyLogWritten: dailyLogWritten,
            completedCount: input.completed.count,
            skippedCount: input.skipped.count,
            progressCount: input.progressMarks.count,
            openLoopCount: input.openLoops.count)
    }

    /// Insert (or, if today already has one, correct) the day's `DailyLog`.
    private func writeDailyLog(summary: String, now: Date) throws {
        let key = Self.dayFactKey(for: now, calendar: calendar)
        switch try store.resolve(DailyLog.self, factKey: key, asOf: now) {
        case let .resolved(existing):
            try store.correct(existing, reason: "Evening capture revised the day's log", asOf: now) {
                $0.summary = summary
            }
        case let .conflict(entries):
            // Correct the most recent to a single active revision rather than leaving a fork.
            if let latest = entries.max(by: { $0.revision < $1.revision }) {
                try store.correct(latest, reason: "Evening capture revised the day's log", asOf: now) {
                    $0.summary = summary
                }
            }
        case .none:
            let log = DailyLog(
                source: .user, createdAt: now, updatedAt: now, logDate: now, summary: summary)
            log.factKey = key
            try store.insert(log)
        }
    }

    /// Stable per-day fact key so a second capture the same day revises the same `DailyLog`.
    static func dayFactKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        return String(format: "daily_log:%04d-%02d-%02d", y, m, d)
    }
}
