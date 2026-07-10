import Foundation
import Core
import Data
import Goals
import Integrations

/// One goal's live state, bundled for the assembler. Holds SwiftData model objects
/// (`GoalTask`/`GoalProgress`), so it is intentionally **not** `Sendable` — construct it on
/// the model context's owning actor (the app's `@MainActor`, or a test's context). The
/// assembler distills it into the fully-serializable `MorningBriefing`.
public struct BriefingGoalInput {
    public let goalID: UUID
    public let goalTitle: String
    public let playbookKey: String
    public let tasks: [GoalTask]
    public let progress: [GoalProgress]
    public let slipRule: SlipRule

    public init(goalID: UUID, goalTitle: String, playbookKey: String,
                tasks: [GoalTask], progress: [GoalProgress], slipRule: SlipRule) {
        self.goalID = goalID
        self.goalTitle = goalTitle
        self.playbookKey = playbookKey
        self.tasks = tasks
        self.progress = progress
        self.slipRule = slipRule
    }

    /// Build directly from a persisted `Goal`, deriving the slip rule from its playbook.
    /// Falls back to a lenient default rule if the playbook key is unknown.
    public init(goal: Goal) {
        let rule = PlaybookLibrary.playbook(forKey: goal.playbookKey)?.slipRule
            ?? SlipRule(gracePeriod: 24 * 3600, requiresCompletionEvidence: true)
        self.init(goalID: goal.appID,
                  goalTitle: goal.title,
                  playbookKey: goal.playbookKey,
                  tasks: goal.tasks ?? [],
                  progress: goal.progress ?? [],
                  slipRule: rule)
    }
}

/// # BriefingAssembler — deterministic, LLM-free Morning Briefing assembly
///
/// Given today's calendar events, each active goal's task/progress state, yesterday's log,
/// open loops, and per-source freshness, produce a `MorningBriefing`. Every decision here is
/// pure Swift: event attribution, "due today" windowing, slip detection (delegated to Phase
/// 3A's `SlipDetector`), and top-priority selection. No network, no model call, no `Date()`
/// — time comes in via `now` so the whole thing is reproducible in tests.
public struct BriefingAssembler {

    private let slipDetector = SlipDetector()

    public init() {}

    /// Assemble the briefing.
    ///
    /// - Parameters:
    ///   - now: the reference instant (inject a `FakeClock.now` in tests).
    ///   - calendar: used only for the start/end-of-day window; inject a fixed-timezone
    ///     calendar in tests for determinism. Defaults to `.current`.
    ///   - calendarEvents: today's events across the user's real + agent calendars. When the
    ///     calendar source is absent this is empty and `calendarFreshness` marks it absent.
    ///   - calendarFreshness / gmailFreshness / healthFreshness: per-source freshness; a
    ///     withheld/never-synced source becomes an explicit absent marker in the output.
    ///   - goals: each active goal's task/progress state.
    ///   - yesterday: yesterday's `DailyLog`, if any.
    ///   - openLoops: active, unresolved open loops.
    public func assemble(
        now: Date,
        calendar: Calendar = .current,
        calendarEvents: [CalendarEventDTO],
        calendarFreshness: SourceFreshness,
        gmailFreshness: SourceFreshness,
        healthFreshness: SourceFreshness,
        goals: [BriefingGoalInput],
        yesterday: DailyLog?,
        openLoops: [OpenLoop]
    ) -> MorningBriefing {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let todayRange = dayStart..<dayEnd

        // 1. Calendar events, attributed and split. Only events that touch today.
        let todaysEvents = calendarEvents
            .filter { $0.start < dayEnd && $0.end > dayStart }
            .sorted { $0.start < $1.start }
        let realEvents = todaysEvents
            .filter { !$0.isAgentOwned }
            .map(Self.event(from:))
        let agentEvents = todaysEvents
            .filter { $0.isAgentOwned }
            .map(Self.event(from:))

        // 2. Due-today tasks and 3. slipped items, per goal.
        var dueTasks: [BriefingTask] = []
        var slippedItems: [BriefingTask] = []
        for goal in goals {
            for task in goal.tasks where isDueToday(task, in: todayRange) {
                dueTasks.append(Self.task(from: task, goal: goal))
            }
            let slipped = slipDetector.slippedTasks(
                tasks: goal.tasks, progress: goal.progress, rule: goal.slipRule, asOf: now)
            slippedItems.append(contentsOf: slipped.map { Self.task(from: $0, goal: goal) })
        }
        // Deterministic order: highest priority first, then earliest start.
        dueTasks.sort(by: Self.priorityThenTime)
        slippedItems.sort(by: Self.priorityThenTime)

        // 4. Yesterday's captured reality.
        let yesterdayLog = yesterday.map {
            BriefingDailyLog(date: $0.logDate, summary: $0.summary)
        }

        // 5. Open loops carried into today.
        let loops = openLoops
            .sorted { $0.createdAt < $1.createdAt }
            .map { BriefingOpenLoop(id: $0.appID, title: $0.title, detail: $0.detail) }

        // 6. Source freshness — every source present, absent ones explicitly marked.
        let sources = [
            SourceFreshnessSnapshot(freshness: calendarFreshness, asOf: now),
            SourceFreshnessSnapshot(freshness: gmailFreshness, asOf: now),
            SourceFreshnessSnapshot(freshness: healthFreshness, asOf: now)
        ]

        // 7. Top priority: the highest-priority due task; if nothing is due, the most urgent
        // slipped item (so the headline still surfaces the day's real signal).
        let topPriority = dueTasks.first ?? slippedItems.first

        return MorningBriefing(
            date: dayStart,
            realEvents: realEvents,
            agentEvents: agentEvents,
            dueTasks: dueTasks,
            slippedItems: slippedItems,
            yesterday: yesterdayLog,
            openLoops: loops,
            sources: sources,
            topPriority: topPriority)
    }

    // MARK: - Helpers

    /// A task is "due today" if it is not complete and its acceptable window overlaps today.
    private func isDueToday(_ task: GoalTask, in today: Range<Date>) -> Bool {
        guard !task.isComplete else { return false }
        let start = task.earliestAcceptable ?? task.latestAcceptable
        let end = task.latestAcceptable ?? task.earliestAcceptable
        guard let start, let end else { return false }
        // Overlap test: window [start, end] intersects [todayStart, todayEnd).
        return start < today.upperBound && end >= today.lowerBound
    }

    private static func event(from dto: CalendarEventDTO) -> BriefingEvent {
        BriefingEvent(id: dto.id, title: dto.title, start: dto.start, end: dto.end,
                      isAgentOwned: dto.isAgentOwned)
    }

    private static func task(from task: GoalTask, goal: BriefingGoalInput) -> BriefingTask {
        BriefingTask(
            taskID: task.appID,
            goalID: goal.goalID,
            goalTitle: goal.goalTitle,
            title: task.title,
            flexibility: task.flexibility,
            priority: task.priority,
            earliestAcceptable: task.earliestAcceptable,
            latestAcceptable: task.latestAcceptable,
            isComplete: task.isComplete)
    }

    private static func priorityThenTime(_ a: BriefingTask, _ b: BriefingTask) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        let ea = a.earliestAcceptable ?? .distantFuture
        let eb = b.earliestAcceptable ?? .distantFuture
        return ea < eb
    }
}
