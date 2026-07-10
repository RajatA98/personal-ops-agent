import Foundation
import SwiftData
import Core
import Data
import DailyLoop
@testable import Agent

/// Shared fixtures + helpers for the Phase 5 golden eval set.
@MainActor
enum AgentTestSupport {

    static func context() throws -> ModelContext {
        let container = try DataStore.makeContainer(inMemory: true)
        return ModelContext(container)
    }

    static let refDate = Date(timeIntervalSince1970: 1_780_000_000) // fixed, deterministic

    // MARK: - Deterministic briefing fixture (grounding / budget)

    /// A briefing with a clear #1 priority, a slipped item, one real event, one agent block, and
    /// an ABSENT gmail source (the honesty signal). Everything mentionable is in here.
    static func briefingFixture() -> MorningBriefing {
        let goalID = UUID()
        let top = BriefingTask(taskID: UUID(), goalID: goalID, goalTitle: "Triathlon training",
                               title: "Dawn pool swim", flexibility: .fixed, priority: 10,
                               earliestAcceptable: refDate, latestAcceptable: refDate.addingTimeInterval(3600),
                               isComplete: false)
        let slipped = BriefingTask(taskID: UUID(), goalID: goalID, goalTitle: "Triathlon training",
                                   title: "Saturday long ride", flexibility: .fixed, priority: 8,
                                   earliestAcceptable: refDate.addingTimeInterval(-86400),
                                   latestAcceptable: refDate.addingTimeInterval(-3600), isComplete: false)
        return MorningBriefing(
            date: refDate,
            realEvents: [BriefingEvent(id: "e1", title: "Team standup",
                                       start: refDate.addingTimeInterval(7200),
                                       end: refDate.addingTimeInterval(9000), isAgentOwned: false)],
            agentEvents: [BriefingEvent(id: "a1", title: "Strength block",
                                        start: refDate.addingTimeInterval(18000),
                                        end: refDate.addingTimeInterval(21600), isAgentOwned: true)],
            dueTasks: [top],
            slippedItems: [slipped],
            yesterday: BriefingDailyLog(date: refDate.addingTimeInterval(-86400),
                                        summary: "Recovery day, easy walk."),
            openLoops: [BriefingOpenLoop(id: UUID(), title: "Reply to coach", detail: "About race registration")],
            sources: [
                SourceFreshnessSnapshot(source: .calendar, availability: .fresh,
                                        lastSyncedAt: refDate, ageSeconds: 60),
                SourceFreshnessSnapshot(source: .gmail, availability: .unavailable,
                                        lastSyncedAt: nil, ageSeconds: nil)
            ],
            topPriority: top)
    }

    static func weeklyReviewFixture() -> WeeklyReview {
        let goalID = UUID()
        func task(_ title: String, complete: Bool) -> BriefingTask {
            BriefingTask(taskID: UUID(), goalID: goalID, goalTitle: "Triathlon training",
                         title: title, flexibility: .movable, priority: 5,
                         earliestAcceptable: refDate, latestAcceptable: refDate, isComplete: complete)
        }
        return WeeklyReview(
            weekStart: refDate.addingTimeInterval(-7 * 86400),
            weekEnd: refDate,
            goals: [WeeklyGoalRollup(goalID: goalID, goalTitle: "Triathlon training",
                                     completed: [task("Two pool swims", complete: true)],
                                     slipped: [task("One long ride", complete: false)],
                                     nextWeek: [task("Brick workout", complete: false)])],
            degradedSources: [SourceFreshnessSnapshot(source: .healthKit, availability: .permissionWithheld,
                                                      lastSyncedAt: nil, ageSeconds: nil)])
    }

    // MARK: - Seeding memory / goals for the Q&A loop

    static func seedGoal(_ ctx: ModelContext, title: String = "Job search", playbook: String = "job_search") {
        let goal = Goal(factKey: "goal:\(title)", title: title, playbookKey: playbook)
        ctx.insert(goal)
        try? ctx.save()
    }

    static func seedPreference(_ ctx: ModelContext, key: String, value: String) {
        let pref = Preference(factKey: "preference:\(key)", key: key, value: value)
        ctx.insert(pref)
        try? ctx.save()
    }
}

/// A pure grounding checker (usable in CI against a scripted narrative, and on-demand against a
/// live Gemini narrative). Verifies a narrative mentions the facts it must and mentions none of
/// the entities that are absent from the context (fabrication markers). Case-insensitive.
enum GroundingChecker {
    struct Result: Equatable {
        var missing: [String]      // required facts not mentioned
        var fabricated: [String]   // out-of-context entities that appeared
        var isGrounded: Bool { missing.isEmpty && fabricated.isEmpty }
    }

    static func check(narrative: String, mustMention: [String], mustNotMention: [String]) -> Result {
        let hay = narrative.lowercased()
        return Result(
            missing: mustMention.filter { !hay.contains($0.lowercased()) },
            fabricated: mustNotMention.filter { hay.contains($0.lowercased()) })
    }
}
