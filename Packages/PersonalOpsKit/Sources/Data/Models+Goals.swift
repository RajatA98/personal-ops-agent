import Foundation
import SwiftData
import Core

/// Lifecycle of a goal. Goal-specific (not part of the cross-module locked vocabulary),
/// so it lives with the model that uses it.
public enum GoalStatus: String, Equatable, Sendable, Codable, CaseIterable {
    case active, paused, completed, abandoned
}

/// A tracked goal (e.g. "Ironman 70.3 in October", "land a PM role by Q4").
///
/// Relationships are **all optional with defaults and paired inverses** — the CloudKit
/// requirement. `tasks` and `progress` are `[…]?` (CloudKit forbids non-optional to-many)
/// and each child points back via its own optional `goal`. Deletes cascade to children.
@Model
public final class Goal: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.user.rawValue
    public var confidence: Double = 1.0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    public var title: String = ""
    /// Which playbook drives this goal ("training", "job_search"); see `GoalsModule`.
    public var playbookKey: String = ""
    public var statusRaw: String = GoalStatus.active.rawValue
    public var targetDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \GoalTask.goal)
    public var tasks: [GoalTask]? = []

    @Relationship(deleteRule: .cascade, inverse: \GoalProgress.goal)
    public var progress: [GoalProgress]? = []

    public var status: GoalStatus {
        get { GoalStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .user,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        title: String = "",
        playbookKey: String = "",
        status: GoalStatus = .active,
        targetDate: Date? = nil
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.title = title
        self.playbookKey = playbookKey
        self.statusRaw = status.rawValue
        self.targetDate = targetDate
    }

    /// Copies scalar fields only. The goal *plan* (tasks/progress relationships) is managed
    /// structurally by Phase 3A/4A, not carried onto a corrected revision of the goal's
    /// own attributes.
    public func makeRevisionCopy() -> Goal {
        Goal(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            title: title, playbookKey: playbookKey, status: status, targetDate: targetDate
        )
    }
}

/// A single scheduled block within a goal's plan. Structural child of `Goal` (identified,
/// CloudKit-syncable via `appID`) rather than an independently-revisioned memory fact —
/// its "correction" is a goal-plan modification (Phase 4A `modify_goal_plan`).
///
/// Carries the flexibility/priority/time-window/duration/conflict-policy metadata that
/// Phase 4C's conflict detection consumes (`TaskFlexibility` / `ConflictPolicy` from Core).
@Model
public final class GoalTask: AppEntity {
    public var appID: UUID = UUID()
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var title: String = ""
    public var flexibilityRaw: String = TaskFlexibility.movable.rawValue
    public var priority: Int = 0
    public var earliestAcceptable: Date?
    public var latestAcceptable: Date?
    /// Expected duration in seconds.
    public var expectedDuration: TimeInterval = 3600
    public var conflictPolicyRaw: String = ConflictPolicy.warn.rawValue
    public var isComplete: Bool = false

    /// Inverse of `Goal.tasks`. Optional per CloudKit.
    public var goal: Goal?

    public var flexibility: TaskFlexibility {
        get { TaskFlexibility(rawValue: flexibilityRaw) ?? .movable }
        set { flexibilityRaw = newValue.rawValue }
    }

    public var conflictPolicy: ConflictPolicy {
        get { ConflictPolicy(rawValue: conflictPolicyRaw) ?? .warn }
        set { conflictPolicyRaw = newValue.rawValue }
    }

    public init(
        appID: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        title: String = "",
        flexibility: TaskFlexibility = .movable,
        priority: Int = 0,
        earliestAcceptable: Date? = nil,
        latestAcceptable: Date? = nil,
        expectedDuration: TimeInterval = 3600,
        conflictPolicy: ConflictPolicy = .warn,
        isComplete: Bool = false,
        goal: Goal? = nil
    ) {
        self.appID = appID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.flexibilityRaw = flexibility.rawValue
        self.priority = priority
        self.earliestAcceptable = earliestAcceptable
        self.latestAcceptable = latestAcceptable
        self.expectedDuration = expectedDuration
        self.conflictPolicyRaw = conflictPolicy.rawValue
        self.isComplete = isComplete
        self.goal = goal
    }
}

/// A point-in-time progress signal for a goal (append log; each entry is a memory fact).
@Model
public final class GoalProgress: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.user.rawValue
    public var confidence: Double = 1.0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    /// What is being measured ("weekly_long_run_km").
    public var metricKey: String = ""
    public var value: Double = 0
    public var note: String = ""

    /// Inverse of `Goal.progress`. Optional per CloudKit.
    public var goal: Goal?

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .user,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        metricKey: String = "",
        value: Double = 0,
        note: String = "",
        goal: Goal? = nil
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.metricKey = metricKey
        self.value = value
        self.note = note
        self.goal = goal
    }

    public func makeRevisionCopy() -> GoalProgress {
        GoalProgress(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            metricKey: metricKey, value: value, note: note, goal: goal
        )
    }
}
