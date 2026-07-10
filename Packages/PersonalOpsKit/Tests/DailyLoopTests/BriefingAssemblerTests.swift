import XCTest
import SwiftData
import Core
import Data
import Goals
import Integrations
import Fixtures
@testable import DailyLoop

/// Phase 3B acceptance #1 and #2 for the Morning Briefing, asserted on the **structured value**
/// (not the View): real vs agent events attributed separately, due tasks, slipped items, source
/// freshness — and absent Gmail/HealthKit explicitly marked, never silently omitted.
final class BriefingAssemblerTests: XCTestCase {

    private let assembler = BriefingAssembler()

    /// Build a goal with: a due-today task, a slipped task, a completed task, a future task.
    private func seededGoal(in ctx: ModelContext) throws -> Goal {
        let due = DL.task(title: "Swim session", earliest: DL.now.addingTimeInterval(8 * DL.hour),
                          latest: DL.now.addingTimeInterval(9 * DL.hour), priority: 3)
        let slipped = DL.task(title: "Missed long ride",
                              earliest: DL.now.addingTimeInterval(-3 * DL.day),
                              latest: DL.now.addingTimeInterval(-2 * DL.day), priority: 2)
        let done = DL.task(title: "Done run", earliest: DL.now.addingTimeInterval(6 * DL.hour),
                           latest: DL.now.addingTimeInterval(7 * DL.hour), complete: true)
        let future = DL.task(title: "Next week ride",
                             earliest: DL.now.addingTimeInterval(5 * DL.day),
                             latest: DL.now.addingTimeInterval(5 * DL.day + DL.hour))
        return try DL.insertGoal(into: ctx, tasks: [due, slipped, done, future])
    }

    // Acceptance #1: attributed events, due tasks, slipped items, freshness.
    func test_briefingShowsAttributedEventsDueTasksSlippedAndFreshness() throws {
        let ctx = try DL.context()
        let goal = try seededGoal(in: ctx)

        let realEvent = CalendarEventDTO(
            id: "standup", calendarID: "primary", title: "Team standup",
            start: DL.now.addingTimeInterval(10 * DL.hour),
            end: DL.now.addingTimeInterval(11 * DL.hour), isAgentOwned: false)
        let agentEvent = CalendarEventDTO(
            id: "swim-block", calendarID: "agent", title: "Swim (agent)",
            start: DL.now.addingTimeInterval(8 * DL.hour),
            end: DL.now.addingTimeInterval(9 * DL.hour), isAgentOwned: true)

        let briefing = assembler.assemble(
            now: DL.now, calendar: DL.utc,
            calendarEvents: [realEvent, agentEvent],
            calendarFreshness: DL.freshCalendar(),
            gmailFreshness: DL.absentGmail(),
            healthFreshness: DL.withheldHealth(),
            goals: [BriefingGoalInput(goal: goal)],
            yesterday: nil, openLoops: [])

        // Real vs agent events attributed separately.
        XCTAssertEqual(briefing.realEvents.map(\.title), ["Team standup"])
        XCTAssertEqual(briefing.agentEvents.map(\.title), ["Swim (agent)"])
        XCTAssertTrue(briefing.realEvents.allSatisfy { !$0.isAgentOwned })
        XCTAssertTrue(briefing.agentEvents.allSatisfy { $0.isAgentOwned })

        // Due tasks include the swim, exclude the completed run and the future ride.
        XCTAssertEqual(briefing.dueTasks.map(\.title), ["Swim session"])

        // Slipped items include the missed long ride.
        XCTAssertEqual(briefing.slippedItems.map(\.title), ["Missed long ride"])

        // Source freshness: calendar fresh, present for all three sources.
        XCTAssertEqual(briefing.sources.map(\.source), [.calendar, .gmail, .healthKit])
        XCTAssertEqual(briefing.source(.calendar)?.availability, .fresh)

        // Top priority is the highest-priority due task.
        XCTAssertEqual(briefing.topPriority?.title, "Swim session")

        // The structured value round-trips through Codable (Phase 5 will serialize it).
        let data = try JSONEncoder().encode(briefing)
        let decoded = try JSONDecoder().decode(MorningBriefing.self, from: data)
        XCTAssertEqual(decoded, briefing)
    }

    // Acceptance #2: succeeds with Gmail/HealthKit absent; absence explicitly marked.
    func test_briefingMarksAbsentSourcesExplicitly() throws {
        let ctx = try DL.context()
        let goal = try seededGoal(in: ctx)

        let briefing = assembler.assemble(
            now: DL.now, calendar: DL.utc,
            calendarEvents: [],
            calendarFreshness: DL.freshCalendar(),
            gmailFreshness: DL.absentGmail(),
            healthFreshness: DL.withheldHealth(),
            goals: [BriefingGoalInput(goal: goal)],
            yesterday: nil, openLoops: [])

        // Gmail and HealthKit are present in the value, explicitly marked absent — not dropped.
        XCTAssertEqual(briefing.source(.gmail)?.availability, .unavailable)
        XCTAssertEqual(briefing.source(.healthKit)?.availability, .permissionWithheld)
        XCTAssertTrue(briefing.source(.gmail)?.isAbsent == true)
        XCTAssertTrue(briefing.source(.healthKit)?.isAbsent == true)
        XCTAssertEqual(Set(briefing.absentSources.map(\.source)), [.gmail, .healthKit])

        // The briefing still generated its goal-derived content despite the absent sources.
        XCTAssertFalse(briefing.dueTasks.isEmpty)
        XCTAssertFalse(briefing.slippedItems.isEmpty)
    }

    func test_yesterdayLogAndOpenLoopsCarryThrough() throws {
        let ctx = try DL.context()
        let goal = try seededGoal(in: ctx)

        let yesterday = DailyLog(createdAt: DL.now.addingTimeInterval(-DL.day),
                                 logDate: DL.now.addingTimeInterval(-DL.day),
                                 summary: "Swam 2km, skipped strength")
        let loop = OpenLoop(createdAt: DL.now.addingTimeInterval(-2 * DL.day),
                            title: "Recruiter reply", detail: "Waiting since Monday")

        let briefing = assembler.assemble(
            now: DL.now, calendar: DL.utc,
            calendarEvents: [],
            calendarFreshness: DL.freshCalendar(),
            gmailFreshness: DL.absentGmail(),
            healthFreshness: DL.withheldHealth(),
            goals: [BriefingGoalInput(goal: goal)],
            yesterday: yesterday, openLoops: [loop])

        XCTAssertEqual(briefing.yesterday?.summary, "Swam 2km, skipped strength")
        XCTAssertEqual(briefing.openLoops.map(\.title), ["Recruiter reply"])
    }
}
