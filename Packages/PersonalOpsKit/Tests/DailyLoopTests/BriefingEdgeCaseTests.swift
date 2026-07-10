import XCTest
import SwiftData
import Core
import Data
import Goals
import Integrations
import Fixtures
@testable import DailyLoop

/// Test-QA edge-case probe (Phase 8). Highest-risk untested Morning-Briefing edges:
/// (1) the fully-empty day — no goals, events, loops — must produce a coherent briefing with a
/// nil top priority and all sources still present-and-marked, never a crash or a phantom headline;
/// (2) "due today" must honor the *injected* calendar's timezone, not a hardcoded zone — the same
/// absolute task window is due under UTC but not under a shifted calendar whose local day differs.
final class BriefingEdgeCaseTests: XCTestCase {

    private let assembler = BriefingAssembler()

    /// Empty state: no goals, no events, no open loops, no yesterday. The briefing is still
    /// well-formed — empty content buckets, nil top priority, all three sources present.
    func test_emptyDay_producesCoherentBriefing_nilTopPriority() throws {
        let briefing = assembler.assemble(
            now: DL.now, calendar: DL.utc,
            calendarEvents: [],
            calendarFreshness: DL.freshCalendar(),
            gmailFreshness: DL.absentGmail(),
            healthFreshness: DL.withheldHealth(),
            goals: [],
            yesterday: nil, openLoops: [])

        XCTAssertTrue(briefing.realEvents.isEmpty)
        XCTAssertTrue(briefing.agentEvents.isEmpty)
        XCTAssertTrue(briefing.dueTasks.isEmpty)
        XCTAssertTrue(briefing.slippedItems.isEmpty)
        XCTAssertTrue(briefing.openLoops.isEmpty)
        XCTAssertNil(briefing.yesterday)
        // No fabricated headline when there is genuinely nothing to prioritize.
        XCTAssertNil(briefing.topPriority)
        // Sources are always present-and-marked, even on an empty day (degrade visibly).
        XCTAssertEqual(briefing.sources.map(\.source), [.calendar, .gmail, .healthKit])
        XCTAssertEqual(Set(briefing.absentSources.map(\.source)), [.gmail, .healthKit])
        // The empty briefing still round-trips through Codable.
        let data = try JSONEncoder().encode(briefing)
        XCTAssertEqual(try JSONDecoder().decode(MorningBriefing.self, from: data), briefing)
    }

    /// A calendar with a fixed non-UTC offset. Deliberately not `.current` so the test is
    /// host-independent.
    private func calendar(offsetHours: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)!
        return c
    }

    /// Timezone/day-boundary correctness: a task window at 23:30–00:30 UTC is "due today" under a
    /// UTC calendar, but the SAME absolute window is NOT due today under a UTC-5 calendar (whose
    /// local day, for the same `now`, ends at 05:00 UTC). Proves the assembler windows against the
    /// injected calendar's timezone rather than a hardcoded one.
    func test_dueToday_honorsInjectedCalendarTimezone() throws {
        let ctx = try DL.context()
        // now = day 10, 00:00:00 UTC (DL.now). Task late in the UTC day.
        let late = DL.task(title: "Late swim",
                           earliest: DL.now.addingTimeInterval(23.5 * DL.hour),
                           latest: DL.now.addingTimeInterval(24.5 * DL.hour))
        let goal = try DL.insertGoal(into: ctx, tasks: [late])

        func dueTitles(using cal: Calendar) -> [String] {
            assembler.assemble(
                now: DL.now, calendar: cal,
                calendarEvents: [],
                calendarFreshness: DL.freshCalendar(),
                gmailFreshness: DL.absentGmail(),
                healthFreshness: DL.withheldHealth(),
                goals: [BriefingGoalInput(goal: goal)],
                yesterday: nil, openLoops: []
            ).dueTasks.map(\.title)
        }

        // Under UTC the task falls inside today's window → due.
        XCTAssertEqual(dueTitles(using: calendar(offsetHours: 0)), ["Late swim"])
        // Under UTC-5 the same instant is still the *previous* local day, whose window ends at
        // 05:00 UTC — the 23:30 UTC task is beyond it → not due today.
        XCTAssertEqual(dueTitles(using: calendar(offsetHours: -5)), [])
    }
}
