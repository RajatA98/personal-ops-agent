import Foundation
import SwiftData
import Core
import Data
import Goals

/// Shared fixtures for the Phase 3B daily-loop tests. Everything runs against an in-memory
/// `ModelContainer` (nothing touches disk) and a fixed-timezone calendar so windowing is
/// deterministic regardless of the host machine's locale.
enum DL {

    /// UTC gregorian calendar — fixed so "today" / day-key math is host-independent.
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Day 10, 00:00:00 UTC — a clean start-of-day anchor for tests.
    static let now = Date(timeIntervalSince1970: 10 * 86_400)

    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    static func context() throws -> ModelContext {
        ModelContext(try DataStore.makeContainer(inMemory: true))
    }

    /// A fresh calendar-source freshness (synced a minute ago).
    static func freshCalendar(at now: Date = DL.now) -> SourceFreshness {
        SourceFreshness(source: .calendar, lastSuccessfulSync: now.addingTimeInterval(-60),
                        stalenessThreshold: 15 * 60)
    }

    /// Gmail never synced → unavailable → absent.
    static func absentGmail() -> SourceFreshness {
        SourceFreshness(source: .gmail, lastSuccessfulSync: nil, stalenessThreshold: 15 * 60)
    }

    /// HealthKit permission withheld → absent.
    static func withheldHealth() -> SourceFreshness {
        SourceFreshness(source: .healthKit, lastSuccessfulSync: nil,
                        stalenessThreshold: 15 * 60, permissionWithheld: true)
    }

    /// Insert a persisted `Goal` (training playbook) with the given tasks into `ctx`.
    @discardableResult
    static func insertGoal(
        into ctx: ModelContext,
        title: String = "Ironman 70.3",
        playbookKey: String = "training",
        tasks: [GoalTask],
        now: Date = DL.now
    ) throws -> Goal {
        let goal = Goal(source: .user, createdAt: now, updatedAt: now,
                        title: title, playbookKey: playbookKey, status: .active)
        goal.factKey = "goal:\(title.lowercased().replacingOccurrences(of: " ", with: "_"))"
        goal.tasks = tasks
        let store = MemoryStore(context: ctx)
        try store.insert(goal)
        return goal
    }

    static func task(
        title: String,
        earliest: Date?,
        latest: Date?,
        flexibility: TaskFlexibility = .fixed,
        priority: Int = 2,
        complete: Bool = false,
        now: Date = DL.now
    ) -> GoalTask {
        GoalTask(createdAt: now, updatedAt: now, title: title, flexibility: flexibility,
                 priority: priority, earliestAcceptable: earliest, latestAcceptable: latest,
                 expectedDuration: 3600, conflictPolicy: .warn, isComplete: complete)
    }
}
