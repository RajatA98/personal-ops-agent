import Foundation
import Core

/// # Goal playbook schema (the eight PRD elements, as data — not code)
///
/// A `GoalPlaybook` is a **pure value description** of how one *kind* of goal is planned,
/// scheduled, tracked, and judged. The PRD (`PRD.md` "Goals") requires a playbook to define
/// exactly eight things:
///
///   1. intake questions        (`intakeQuestions`)
///   2. milestone schema        (`milestoneTemplates`)
///   3. task-generation rules   (`taskRules`)
///   4. progress signals        (`progressSignals`)
///   5. review cadence          (`reviewCadence`)
///   6. slip-detection rules    (`slipRule`)
///   7. schedule-block templates(`scheduleBlockTemplates`)
///   8. completion criteria     (`completionCriteria`)
///
/// The single, playbook-agnostic engine (`GoalPlanner`, `SchedulePreviewBuilder`,
/// `SlipDetector`) reads *this data* to produce a plan/preview/slip verdict. Two goal
/// types differ only by the data they carry here — never by a separate code path. That is
/// the PRD's explicit red-flag guard against "two hardcoded paths behind a common wrapper."
public struct GoalPlaybook: Sendable, Equatable {
    /// Stable key persisted on `Goal.playbookKey` (e.g. `"training"`, `"job_search"`).
    public let key: String
    public let displayName: String

    // 1. Intake questions asked before a plan can be generated.
    public let intakeQuestions: [IntakeQuestion]
    // 2. Milestones derived from the goal's timeline (now → target date).
    public let milestoneTemplates: [MilestoneTemplate]
    // 3. Recurring task-generation rules — the heart of the plan.
    public let taskRules: [TaskRule]
    // 4. The progress metrics this goal type tracks (drives `GoalProgress.metricKey`).
    public let progressSignals: [ProgressSignal]
    // 5. When the weekly/periodic review runs.
    public let reviewCadence: ReviewCadence
    // 6. How to decide a task has slipped.
    public let slipRule: SlipRule
    // 7. Named time-of-day/day-of-week windows tasks are placed into.
    public let scheduleBlockTemplates: [ScheduleBlockTemplate]
    // 8. What "done" means for the whole goal.
    public let completionCriteria: [CompletionCriterion]

    public init(
        key: String,
        displayName: String,
        intakeQuestions: [IntakeQuestion],
        milestoneTemplates: [MilestoneTemplate],
        taskRules: [TaskRule],
        progressSignals: [ProgressSignal],
        reviewCadence: ReviewCadence,
        slipRule: SlipRule,
        scheduleBlockTemplates: [ScheduleBlockTemplate],
        completionCriteria: [CompletionCriterion]
    ) {
        self.key = key
        self.displayName = displayName
        self.intakeQuestions = intakeQuestions
        self.milestoneTemplates = milestoneTemplates
        self.taskRules = taskRules
        self.progressSignals = progressSignals
        self.reviewCadence = reviewCadence
        self.slipRule = slipRule
        self.scheduleBlockTemplates = scheduleBlockTemplates
        self.completionCriteria = completionCriteria
    }

    /// Look up a schedule-block template by key (the `TaskRule.scheduleBlockKey` reference).
    public func scheduleBlock(_ key: String) -> ScheduleBlockTemplate? {
        scheduleBlockTemplates.first { $0.key == key }
    }
}

// MARK: - 1. Intake

/// One question asked during goal creation. `kind` tells the UI how to render it and tells
/// the planner how to read the answer.
public struct IntakeQuestion: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case number, date, choice, text
    }
    public let id: String
    public let prompt: String
    public let kind: Kind
    /// Allowed values for `.choice` questions (empty otherwise).
    public let choices: [String]
    /// Display unit for `.number` questions (e.g. "hours/week"); nil otherwise.
    public let unit: String?

    public init(id: String, prompt: String, kind: Kind, choices: [String] = [], unit: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.kind = kind
        self.choices = choices
        self.unit = unit
    }
}

/// A single typed intake answer.
public enum IntakeAnswer: Sendable, Equatable {
    case number(Double)
    case date(Date)
    case choice(String)
    case text(String)

    public var numberValue: Double? { if case let .number(v) = self { return v }; return nil }
    public var dateValue: Date? { if case let .date(v) = self { return v }; return nil }
    public var stringValue: String? {
        switch self {
        case let .choice(v): return v
        case let .text(v): return v
        default: return nil
        }
    }
}

/// The user's answers to a playbook's intake questions, keyed by `IntakeQuestion.id`.
public struct IntakeAnswers: Sendable, Equatable {
    public private(set) var values: [String: IntakeAnswer]
    public init(_ values: [String: IntakeAnswer] = [:]) { self.values = values }

    public subscript(_ id: String) -> IntakeAnswer? { values[id] }
    public mutating func set(_ id: String, _ answer: IntakeAnswer) { values[id] = answer }

    public func number(_ id: String) -> Double? { values[id]?.numberValue }
    public func date(_ id: String) -> Date? { values[id]?.dateValue }
    public func string(_ id: String) -> String? { values[id]?.stringValue }
}

// MARK: - 2. Milestones

/// A milestone placed at a fraction of the goal's timeline (0 = start, 1 = target date).
public struct MilestoneTemplate: Sendable, Equatable {
    public let key: String
    public let title: String
    /// Position along `now → targetDate`, clamped to 0...1.
    public let timelineFraction: Double

    public init(key: String, title: String, timelineFraction: Double) {
        self.key = key
        self.title = title
        self.timelineFraction = min(max(timelineFraction, 0), 1)
    }
}

// MARK: - 3. Task-generation rules

/// A rule that expands into recurring `GoalTask`s across the plan's weeks. Every scheduling
/// attribute a `GoalTask` carries (flexibility / priority / conflict policy / duration) is
/// declared here as **data**, so the difference between a fixed dawn swim and a movable
/// networking block is a difference in these fields — not in code.
public struct TaskRule: Sendable, Equatable {
    public let key: String
    public let titleTemplate: String
    public let flexibility: TaskFlexibility
    public let priority: Int
    public let conflictPolicy: ConflictPolicy
    /// Expected duration in seconds.
    public let expectedDuration: TimeInterval
    /// How many of these occur per week.
    public let weeklyFrequency: Int
    /// Which `ScheduleBlockTemplate` (by key) places this task in the day/week.
    public let scheduleBlockKey: String

    public init(
        key: String,
        titleTemplate: String,
        flexibility: TaskFlexibility,
        priority: Int,
        conflictPolicy: ConflictPolicy,
        expectedDuration: TimeInterval,
        weeklyFrequency: Int,
        scheduleBlockKey: String
    ) {
        self.key = key
        self.titleTemplate = titleTemplate
        self.flexibility = flexibility
        self.priority = priority
        self.conflictPolicy = conflictPolicy
        self.expectedDuration = expectedDuration
        self.weeklyFrequency = weeklyFrequency
        self.scheduleBlockKey = scheduleBlockKey
    }
}

// MARK: - 4. Progress signals

/// A metric this goal type tracks over time (maps to `GoalProgress.metricKey`).
public struct ProgressSignal: Sendable, Equatable {
    public let metricKey: String
    public let label: String
    public let unit: String

    public init(metricKey: String, label: String, unit: String) {
        self.metricKey = metricKey
        self.label = label
        self.unit = unit
    }
}

// MARK: - 5. Review cadence

/// When the periodic review runs. Weekday is 1 = Sunday … 7 = Saturday (Foundation's
/// convention), `everyNWeeks` = 1 for weekly.
public struct ReviewCadence: Sendable, Equatable {
    public let weekday: Int
    public let everyNWeeks: Int
    public init(weekday: Int, everyNWeeks: Int = 1) {
        self.weekday = weekday
        self.everyNWeeks = everyNWeeks
    }
}

// MARK: - 6. Slip rule

/// How slip detection judges a task overdue. A task is *slipped* when it is not complete,
/// `asOf` is past its `latestAcceptable + gracePeriod`, and (if evidence is required) no
/// progress covers its window.
public struct SlipRule: Sendable, Equatable {
    /// Extra time allowed past `latestAcceptable` before a task counts as slipped.
    public let gracePeriod: TimeInterval
    /// Whether a matching `GoalProgress` entry within the task window clears the slip.
    public let requiresCompletionEvidence: Bool

    public init(gracePeriod: TimeInterval, requiresCompletionEvidence: Bool = true) {
        self.gracePeriod = gracePeriod
        self.requiresCompletionEvidence = requiresCompletionEvidence
    }
}

// MARK: - 7. Schedule-block templates

/// A named time window a task is placed into. Purely arithmetic (offset from the week
/// start) so scheduling is deterministic and timezone-independent for tests.
public struct ScheduleBlockTemplate: Sendable, Equatable {
    public let key: String
    /// Preferred weekday (1 = Sunday … 7 = Saturday). `nil` = spread across the work week.
    public let weekday: Int?
    /// Start hour of day, 0...23.
    public let startHour: Int

    public init(key: String, weekday: Int? = nil, startHour: Int) {
        self.key = key
        self.weekday = weekday
        self.startHour = startHour
    }
}

// MARK: - 8. Completion criteria

/// What "the whole goal is done" means. A goal is complete when *any* criterion is met.
public enum CompletionCriterion: Sendable, Equatable {
    /// A tracked metric reaches (or exceeds) a threshold.
    case metricThreshold(metricKey: String, atLeast: Double)
    /// The goal's target date has arrived.
    case targetDateReached
}
