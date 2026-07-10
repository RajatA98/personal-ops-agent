import Foundation
import Core

/// # The shipped playbooks
///
/// Two real playbooks — **Triathlon Training** and **Job Search** — expressed entirely as
/// `GoalPlaybook` *data*. They flow through the same `GoalPlanner`/`SchedulePreviewBuilder`/
/// `SlipDetector`, so the fact that a training plan is dense with `fixed`/`block` dawn
/// workouts while a job-search plan is mostly `movable`/`optional` `warn`/`allow` blocks is
/// a difference in these values — not in any branch of engine code.
public enum PlaybookLibrary {

    /// All shipped playbooks, in display order.
    public static var all: [GoalPlaybook] { [triathlonTraining, jobSearch] }

    /// Look up a playbook by its persisted key. Returns `nil` for an unknown key.
    public static func playbook(forKey key: String) -> GoalPlaybook? {
        all.first { $0.key == key }
    }

    // MARK: Triathlon Training

    /// Endurance training: a week is anchored by hard, immovable workouts (a dawn swim in a
    /// booked pool lane, a Saturday long ride) that should *block* conflicts, plus a couple
    /// of softer sessions. Milestones follow the classic base → build → peak → taper arc.
    public static let triathlonTraining = GoalPlaybook(
        key: "training",
        displayName: "Triathlon Training",
        intakeQuestions: [
            IntakeQuestion(id: "race_date", prompt: "When is your race?", kind: .date),
            IntakeQuestion(id: "race_distance", prompt: "Which distance?", kind: .choice,
                           choices: ["sprint", "olympic", "70.3", "full"]),
            IntakeQuestion(id: "weekly_hours", prompt: "How many hours can you train per week?",
                           kind: .number, unit: "hours/week"),
            IntakeQuestion(id: "pool_access", prompt: "Do you have pool access?", kind: .choice,
                           choices: ["yes", "no"])
        ],
        milestoneTemplates: [
            MilestoneTemplate(key: "base",  title: "Base phase — build aerobic volume", timelineFraction: 0.0),
            MilestoneTemplate(key: "build", title: "Build phase — add intensity",       timelineFraction: 0.40),
            MilestoneTemplate(key: "peak",  title: "Peak phase — race-specific work",    timelineFraction: 0.75),
            MilestoneTemplate(key: "taper", title: "Taper — freshen up",                 timelineFraction: 0.90),
            MilestoneTemplate(key: "race",  title: "Race day",                           timelineFraction: 1.0)
        ],
        taskRules: [
            // Immovable, blocking anchors — a booked pool lane / group long ride.
            TaskRule(key: "swim",     titleTemplate: "Swim session",  flexibility: .fixed,
                     priority: 3, conflictPolicy: .block, expectedDuration: 3600,
                     weeklyFrequency: 2, scheduleBlockKey: "dawn_pool"),
            TaskRule(key: "long_ride", titleTemplate: "Long ride",    flexibility: .fixed,
                     priority: 3, conflictPolicy: .block, expectedDuration: 9000,
                     weeklyFrequency: 1, scheduleBlockKey: "weekend_long"),
            TaskRule(key: "brick",    titleTemplate: "Brick (bike + run)", flexibility: .fixed,
                     priority: 3, conflictPolicy: .block, expectedDuration: 7200,
                     weeklyFrequency: 1, scheduleBlockKey: "weekend_long"),
            // Softer sessions the scheduler may move.
            TaskRule(key: "run",      titleTemplate: "Run session",   flexibility: .movable,
                     priority: 2, conflictPolicy: .warn, expectedDuration: 2700,
                     weeklyFrequency: 2, scheduleBlockKey: "evening"),
            TaskRule(key: "strength", titleTemplate: "Strength & mobility", flexibility: .optional,
                     priority: 1, conflictPolicy: .allow, expectedDuration: 1800,
                     weeklyFrequency: 1, scheduleBlockKey: "flexible")
        ],
        progressSignals: [
            ProgressSignal(metricKey: "weekly_swim_km",  label: "Swim volume",  unit: "km"),
            ProgressSignal(metricKey: "weekly_bike_km",  label: "Bike volume",  unit: "km"),
            ProgressSignal(metricKey: "weekly_run_km",   label: "Run volume",   unit: "km"),
            ProgressSignal(metricKey: "long_ride_km",    label: "Longest ride", unit: "km")
        ],
        reviewCadence: ReviewCadence(weekday: 1, everyNWeeks: 1), // Sunday
        slipRule: SlipRule(gracePeriod: 12 * 3600, requiresCompletionEvidence: true),
        scheduleBlockTemplates: [
            ScheduleBlockTemplate(key: "dawn_pool",    weekday: nil, startHour: 6),
            ScheduleBlockTemplate(key: "evening",      weekday: nil, startHour: 18),
            ScheduleBlockTemplate(key: "weekend_long", weekday: 7,   startHour: 8),   // Saturday
            ScheduleBlockTemplate(key: "flexible",     weekday: nil, startHour: 12)
        ],
        completionCriteria: [
            .targetDateReached
        ],
        // Phase 3C: HealthKit may ease the *softer* sessions (run, strength) under poor
        // recovery — never the immovable swim/ride/brick anchors — and only within bounds:
        // at most one session dropped, never shorter than 60% of the planned duration.
        pacingPolicy: PacingPolicy(
            adjustableRuleKeys: ["run", "strength"],
            minDurationScale: 0.6,
            maxFrequencyReduction: 1,
            poorDurationScale: 0.8,
            poorFrequencyReduction: 1)
    )

    // MARK: Job Search

    /// Job search: a pipeline funnel. High-volume application sending and interview prep are
    /// `movable`/`warn` (do them, but around real commitments); networking and portfolio
    /// work are `optional`/`allow`. Nothing here is `fixed`/`block` — a job search should
    /// yield to a real meeting, never bulldoze it. Milestones follow the funnel, not a
    /// training arc.
    public static let jobSearch = GoalPlaybook(
        key: "job_search",
        displayName: "Job Search",
        intakeQuestions: [
            IntakeQuestion(id: "target_role", prompt: "What role are you targeting?", kind: .text),
            IntakeQuestion(id: "target_date", prompt: "By when do you want an offer?", kind: .date),
            IntakeQuestion(id: "weekly_applications", prompt: "How many applications per week?",
                           kind: .number, unit: "apps/week"),
            IntakeQuestion(id: "have_resume", prompt: "Is your resume ready?", kind: .choice,
                           choices: ["yes", "no"])
        ],
        milestoneTemplates: [
            MilestoneTemplate(key: "resume",       title: "Resume & materials ready", timelineFraction: 0.10),
            MilestoneTemplate(key: "pipeline",     title: "Pipeline built",           timelineFraction: 0.35),
            MilestoneTemplate(key: "interviewing", title: "Actively interviewing",    timelineFraction: 0.60),
            MilestoneTemplate(key: "offers",       title: "Offers in hand",           timelineFraction: 0.90),
            MilestoneTemplate(key: "decision",     title: "Decision & accept",        timelineFraction: 1.0)
        ],
        taskRules: [
            TaskRule(key: "applications", titleTemplate: "Send applications", flexibility: .movable,
                     priority: 3, conflictPolicy: .warn, expectedDuration: 1800,
                     weeklyFrequency: 5, scheduleBlockKey: "workday"),
            TaskRule(key: "interview_prep", titleTemplate: "Interview prep", flexibility: .movable,
                     priority: 3, conflictPolicy: .warn, expectedDuration: 3600,
                     weeklyFrequency: 2, scheduleBlockKey: "evening"),
            TaskRule(key: "networking", titleTemplate: "Networking outreach", flexibility: .optional,
                     priority: 2, conflictPolicy: .allow, expectedDuration: 2700,
                     weeklyFrequency: 2, scheduleBlockKey: "flexible"),
            TaskRule(key: "portfolio", titleTemplate: "Portfolio / project work", flexibility: .optional,
                     priority: 1, conflictPolicy: .allow, expectedDuration: 5400,
                     weeklyFrequency: 1, scheduleBlockKey: "weekend_long")
        ],
        progressSignals: [
            ProgressSignal(metricKey: "applications_sent",       label: "Applications sent",   unit: "count"),
            ProgressSignal(metricKey: "interviews_scheduled",    label: "Interviews scheduled", unit: "count"),
            ProgressSignal(metricKey: "offers_received",         label: "Offers received",     unit: "count"),
            ProgressSignal(metricKey: "networking_conversations", label: "Networking chats",    unit: "count")
        ],
        reviewCadence: ReviewCadence(weekday: 1, everyNWeeks: 1), // Sunday
        slipRule: SlipRule(gracePeriod: 24 * 3600, requiresCompletionEvidence: true),
        scheduleBlockTemplates: [
            ScheduleBlockTemplate(key: "workday",      weekday: nil, startHour: 9),
            ScheduleBlockTemplate(key: "evening",      weekday: nil, startHour: 19),
            ScheduleBlockTemplate(key: "flexible",     weekday: nil, startHour: 12),
            ScheduleBlockTemplate(key: "weekend_long", weekday: 7,   startHour: 10)  // Saturday
        ],
        completionCriteria: [
            .metricThreshold(metricKey: "offers_received", atLeast: 1),
            .targetDateReached
        ]
    )
}
