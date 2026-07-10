import Foundation
import Core
import Data

/// # Cross-goal conflict detection (Phase 4C) — deterministic, LLM-free
///
/// Given the scheduled blocks of two or more goals, flags true time overlaps and grades each
/// by the pair's configured `ConflictPolicy` (from Phase 3A's `GoalTask` metadata). This is
/// pure value-type logic: it consumes `ScheduledBlock`s (adaptable from either a persisted
/// `GoalTask` or an in-memory `PlannedTask`), so the *same* detector runs at schedule-preview
/// time (before anything is written) and at the Proposal enqueue seam.
///
/// It never blocks silently — it only *reports* conflicts. Turning a reported conflict into a
/// user-facing Proposal is the Proposals layer's job (`ConflictProposalBuilder`), preserving
/// the "surface it, don't act on it" invariant.

// MARK: - Value types

/// How serious an overlap is, derived from the two overlapping blocks' `ConflictPolicy`.
public enum ConflictSeverity: String, Sendable, Equatable, Codable, CaseIterable {
    /// At least one side's policy is `.block` — a genuine collision the user must resolve.
    case hard
    /// The strictest side is `.warn` — surfaced as a heads-up, not a hard stop.
    case warning
}

/// One goal task's occupied time window plus the scheduling metadata conflict detection needs.
/// Deliberately flat/Sendable so it can be built from a persisted `GoalTask` *or* a preview-only
/// `PlannedTask` and compared without a model container.
public struct ScheduledBlock: Sendable, Equatable {
    /// Stable id of the underlying task (a real `GoalTask.appID` on the persisted path; a
    /// synthesized id on the preview path where nothing is persisted yet).
    public let taskAppID: UUID
    /// Which goal this block belongs to — conflicts are only flagged *across* different goals.
    public let goalID: UUID
    public let goalTitle: String
    public let title: String
    public let start: Date
    public let end: Date
    public let flexibility: TaskFlexibility
    public let priority: Int
    public let conflictPolicy: ConflictPolicy

    public init(taskAppID: UUID, goalID: UUID, goalTitle: String, title: String,
                start: Date, end: Date, flexibility: TaskFlexibility, priority: Int,
                conflictPolicy: ConflictPolicy) {
        self.taskAppID = taskAppID
        self.goalID = goalID
        self.goalTitle = goalTitle
        self.title = title
        self.start = start
        self.end = end
        self.flexibility = flexibility
        self.priority = priority
        self.conflictPolicy = conflictPolicy
    }
}

/// A detected time collision between two blocks from different goals.
public struct ScheduleConflict: Sendable, Equatable {
    /// The block that should hold its slot (the less movable / higher-priority side).
    public let anchor: ScheduledBlock
    /// The block that is the natural candidate to move (more permissive policy / more flexible /
    /// lower priority). A reschedule Proposal targets *this* one.
    public let yielding: ScheduledBlock
    public let severity: ConflictSeverity
    public let overlapStart: Date
    public let overlapEnd: Date

    public init(anchor: ScheduledBlock, yielding: ScheduledBlock, severity: ConflictSeverity,
                overlapStart: Date, overlapEnd: Date) {
        self.anchor = anchor
        self.yielding = yielding
        self.severity = severity
        self.overlapStart = overlapStart
        self.overlapEnd = overlapEnd
    }

    /// A stable key for this conflict, order-independent in the two task ids, so re-running
    /// detection produces the same key (used by the Proposals layer to dedupe).
    public var pairKey: String {
        let ids = [anchor.taskAppID.uuidString, yielding.taskAppID.uuidString].sorted()
        return "\(ids[0])_\(ids[1])"
    }
}

// MARK: - Detector

public struct ConflictDetector: Sendable {
    public init() {}

    /// Combine two tasks' policies into a severity. The rule is "strictest wins":
    ///   • either side `.block`  → `.hard`     (a fixed anchor is involved; must be resolved)
    ///   • else either `.warn`   → `.warning`  (a heads-up)
    ///   • both `.allow`         → `nil`        (overlap permitted; not flagged)
    /// This is what makes the PRD's fixed/fixed, fixed/movable and movable/optional cases fall
    /// out of the *configured* policies rather than being hardcoded per pairing.
    public static func severity(_ p1: ConflictPolicy, _ p2: ConflictPolicy) -> ConflictSeverity? {
        if p1 == .block || p2 == .block { return .hard }
        if p1 == .warn || p2 == .warn { return .warning }
        return nil
    }

    /// True when two windows genuinely overlap (strict — back-to-back adjacency is not a
    /// conflict).
    static func overlaps(_ a: ScheduledBlock, _ b: ScheduledBlock) -> Bool {
        a.start < b.end && b.start < a.end
    }

    /// Detect every cross-goal conflict among `blocks`. Same-goal pairs are never flagged (a
    /// goal's own plan is internally consistent by construction). Output is deterministic:
    /// sorted by overlap start, then by pair key.
    public func detect(blocks: [ScheduledBlock]) -> [ScheduleConflict] {
        var conflicts: [ScheduleConflict] = []
        let ordered = blocks.sorted {
            $0.start != $1.start ? $0.start < $1.start
                                 : $0.taskAppID.uuidString < $1.taskAppID.uuidString
        }
        for i in ordered.indices {
            for j in (i + 1)..<ordered.count {
                let x = ordered[i], y = ordered[j]
                guard x.goalID != y.goalID else { continue }
                guard Self.overlaps(x, y) else { continue }
                guard let sev = Self.severity(x.conflictPolicy, y.conflictPolicy) else { continue }
                let (anchor, yielding) = Self.anchorAndYielding(x, y)
                conflicts.append(ScheduleConflict(
                    anchor: anchor,
                    yielding: yielding,
                    severity: sev,
                    overlapStart: max(x.start, y.start),
                    overlapEnd: min(x.end, y.end)))
            }
        }
        return conflicts.sorted {
            $0.overlapStart != $1.overlapStart ? $0.overlapStart < $1.overlapStart
                                               : $0.pairKey < $1.pairKey
        }
    }

    /// Detect conflicts across several goals given each goal's blocks. Convenience wrapper.
    public func detect(acrossGoals groups: [(goalID: UUID, goalTitle: String, blocks: [ScheduledBlock])])
        -> [ScheduleConflict] {
        detect(blocks: groups.flatMap { $0.blocks })
    }

    /// Decide which block yields. More permissive policy yields first (`allow` > `warn` >
    /// `block`); ties break to the more flexible task (`optional` > `movable` > `fixed`), then
    /// to the lower priority, then to a stable id order so the result is deterministic.
    static func anchorAndYielding(_ x: ScheduledBlock, _ y: ScheduledBlock)
        -> (anchor: ScheduledBlock, yielding: ScheduledBlock) {
        if yieldScore(x) != yieldScore(y) {
            return yieldScore(x) > yieldScore(y) ? (y, x) : (x, y)
        }
        if x.flexScore != y.flexScore {
            return x.flexScore > y.flexScore ? (y, x) : (x, y)
        }
        if x.priority != y.priority {
            // lower priority yields
            return x.priority < y.priority ? (y, x) : (x, y)
        }
        return x.taskAppID.uuidString < y.taskAppID.uuidString ? (x, y) : (y, x)
    }

    /// Higher = more willing to yield.
    private static func yieldScore(_ b: ScheduledBlock) -> Int {
        switch b.conflictPolicy {
        case .allow: return 2
        case .warn:  return 1
        case .block: return 0
        }
    }
}

private extension ScheduledBlock {
    /// Higher = more movable.
    var flexScore: Int {
        switch flexibility {
        case .optional: return 2
        case .movable:  return 1
        case .fixed:    return 0
        }
    }
}

// MARK: - Adapters

public extension ScheduledBlock {
    /// Build blocks from a goal's persisted tasks. Tasks with no scheduled start
    /// (`earliestAcceptable == nil`) occupy no time and are skipped. `end` uses the task's
    /// `expectedDuration` (its `latestAcceptable` includes slip slack, which is not "occupied"
    /// time for overlap purposes).
    static func from(tasks: [GoalTask], goalID: UUID, goalTitle: String) -> [ScheduledBlock] {
        tasks.compactMap { task in
            guard !task.isComplete, let start = task.earliestAcceptable else { return nil }
            return ScheduledBlock(
                taskAppID: task.appID,
                goalID: goalID,
                goalTitle: goalTitle,
                title: task.title,
                start: start,
                end: start.addingTimeInterval(task.expectedDuration),
                flexibility: task.flexibility,
                priority: task.priority,
                conflictPolicy: task.conflictPolicy)
        }
    }

    /// Build blocks from a preview plan's in-memory tasks (nothing persisted yet). Each planned
    /// task gets a synthesized id so detection can run before materialization.
    static func from(planned tasks: [PlannedTask], goalID: UUID, goalTitle: String) -> [ScheduledBlock] {
        tasks.map { task in
            ScheduledBlock(
                taskAppID: UUID(),
                goalID: goalID,
                goalTitle: goalTitle,
                title: task.title,
                start: task.earliestAcceptable,
                end: task.earliestAcceptable.addingTimeInterval(task.expectedDuration),
                flexibility: task.flexibility,
                priority: task.priority,
                conflictPolicy: task.conflictPolicy)
        }
    }
}
