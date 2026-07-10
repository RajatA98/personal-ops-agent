import Foundation
import Core

/// A milestone with a concrete date, produced from a `MilestoneTemplate`.
public struct PlannedMilestone: Sendable, Equatable {
    public let key: String
    public let title: String
    public let date: Date
    public init(key: String, title: String, date: Date) {
        self.key = key
        self.title = title
        self.date = date
    }
}

/// A single scheduled task the planner emits. A pure value (no SwiftData dependency) so the
/// engine is testable without a model container; `GoalPlanMaterializer` turns these into
/// persisted `GoalTask`s. Carries every scheduling attribute Phase 4C's conflict detector
/// consumes (flexibility / priority / conflict policy / time window / duration).
public struct PlannedTask: Sendable, Equatable {
    public let ruleKey: String
    public let title: String
    public let flexibility: TaskFlexibility
    public let priority: Int
    public let conflictPolicy: ConflictPolicy
    public let expectedDuration: TimeInterval
    public let earliestAcceptable: Date
    public let latestAcceptable: Date
    /// 0-based week within the plan horizon.
    public let weekIndex: Int
    /// Non-nil when this task's duration/frequency was adjusted by HealthKit pacing (Phase 3C).
    /// This is the visible "HealthKit-influenced" marker the Goals UI surfaces and tests assert
    /// on. `nil` on every unpaced task, so its presence is unambiguous.
    public let pacing: PacingInfluence?

    public init(
        ruleKey: String,
        title: String,
        flexibility: TaskFlexibility,
        priority: Int,
        conflictPolicy: ConflictPolicy,
        expectedDuration: TimeInterval,
        earliestAcceptable: Date,
        latestAcceptable: Date,
        weekIndex: Int,
        pacing: PacingInfluence? = nil
    ) {
        self.ruleKey = ruleKey
        self.title = title
        self.flexibility = flexibility
        self.priority = priority
        self.conflictPolicy = conflictPolicy
        self.expectedDuration = expectedDuration
        self.earliestAcceptable = earliestAcceptable
        self.latestAcceptable = latestAcceptable
        self.weekIndex = weekIndex
        self.pacing = pacing
    }

    /// The task's intended start (== `earliestAcceptable`).
    public var scheduledStart: Date { earliestAcceptable }

    /// A copy carrying the given HealthKit pacing marker (used by `PacedPlanner`).
    public func stampingPacing(_ influence: PacingInfluence) -> PlannedTask {
        PlannedTask(
            ruleKey: ruleKey, title: title, flexibility: flexibility, priority: priority,
            conflictPolicy: conflictPolicy, expectedDuration: expectedDuration,
            earliestAcceptable: earliestAcceptable, latestAcceptable: latestAcceptable,
            weekIndex: weekIndex, pacing: influence)
    }
}

/// The full generated plan for a goal: its milestones and its scheduled tasks.
public struct GeneratedPlan: Sendable, Equatable {
    public let playbookKey: String
    public let goalTitle: String
    public let startDate: Date
    public let targetDate: Date
    public let milestones: [PlannedMilestone]
    public let tasks: [PlannedTask]

    public init(
        playbookKey: String,
        goalTitle: String,
        startDate: Date,
        targetDate: Date,
        milestones: [PlannedMilestone],
        tasks: [PlannedTask]
    ) {
        self.playbookKey = playbookKey
        self.goalTitle = goalTitle
        self.startDate = startDate
        self.targetDate = targetDate
        self.milestones = milestones
        self.tasks = tasks
    }
}

/// # GoalPlanner — the single, deterministic, LLM-free planning engine
///
/// One algorithm plans **every** goal type. It reads the playbook's `taskRules`,
/// `milestoneTemplates` and `scheduleBlockTemplates` as data and expands them across the
/// weeks between `now` and the target date. Two goal types produce structurally different
/// plans purely because they carry different data — there is no `if playbook == training`
/// anywhere in here. That is the whole point (PRD "Goals" red-flag guard).
///
/// Scheduling math is pure `TimeInterval` arithmetic off the week start, so plans are fully
/// deterministic and timezone-independent (important for reproducible tests).
public struct GoalPlanner: Sendable {

    public init() {}

    private static let week: TimeInterval = 7 * 86_400
    private static let day: TimeInterval = 86_400
    private static let hour: TimeInterval = 3_600

    /// Generate a plan for `playbook`, given intake `answers`, a start (`now`) and a
    /// `targetDate`. `targetDate` at or before `now` yields a single-week horizon so a plan
    /// is always non-empty.
    public func generatePlan(
        playbook: GoalPlaybook,
        answers: IntakeAnswers,
        goalTitle: String,
        now: Date,
        targetDate: Date
    ) -> GeneratedPlan {
        let span = max(targetDate.timeIntervalSince(now), Self.week)
        let weeks = max(1, Int((span / Self.week).rounded(.up)))
        let effectiveTarget = now.addingTimeInterval(Double(weeks) * Self.week)

        let milestones = playbook.milestoneTemplates.map { template in
            PlannedMilestone(
                key: template.key,
                title: template.title,
                date: now.addingTimeInterval(template.timelineFraction * span)
            )
        }

        var tasks: [PlannedTask] = []
        for week in 0..<weeks {
            let weekStart = now.addingTimeInterval(Double(week) * Self.week)
            for rule in playbook.taskRules {
                let template = playbook.scheduleBlock(rule.scheduleBlockKey)
                for occurrence in 0..<max(0, rule.weeklyFrequency) {
                    let start = scheduledStart(
                        weekStart: weekStart, template: template, occurrence: occurrence)
                    let latest = start
                        + rule.expectedDuration
                        + flexWindow(rule.flexibility)
                    tasks.append(PlannedTask(
                        ruleKey: rule.key,
                        title: rule.titleTemplate,
                        flexibility: rule.flexibility,
                        priority: rule.priority,
                        conflictPolicy: rule.conflictPolicy,
                        expectedDuration: rule.expectedDuration,
                        earliestAcceptable: start,
                        latestAcceptable: latest,
                        weekIndex: week))
                }
            }
        }

        return GeneratedPlan(
            playbookKey: playbook.key,
            goalTitle: goalTitle,
            startDate: now,
            targetDate: effectiveTarget,
            milestones: milestones,
            tasks: tasks)
    }

    /// Where in the week this occurrence lands. Templates with a fixed `weekday` pin the day
    /// (a Saturday long ride); templates without one spread occurrences across the work week.
    private func scheduledStart(
        weekStart: Date, template: ScheduleBlockTemplate?, occurrence: Int
    ) -> Date {
        let startHour = template?.startHour ?? 12
        let dayIndex: Int
        if let weekday = template?.weekday {
            dayIndex = max(0, weekday - 1)          // 1=Sun … 7=Sat → 0-based offset
        } else {
            dayIndex = (occurrence % 5)             // Mon-ish through Fri-ish across the week
        }
        return weekStart
            .addingTimeInterval(Double(dayIndex) * Self.day)
            .addingTimeInterval(Double(startHour) * Self.hour)
    }

    /// How much slack past the block's end still counts as "on time" — narrow for fixed
    /// anchors, a same-day window for movable work, several days for optional work. This is
    /// what makes `fixed`/`movable`/`optional` produce genuinely different slip deadlines.
    private func flexWindow(_ flexibility: TaskFlexibility) -> TimeInterval {
        switch flexibility {
        case .fixed:    return 0
        case .movable:  return 6 * Self.hour
        case .optional: return 3 * Self.day
        }
    }
}
