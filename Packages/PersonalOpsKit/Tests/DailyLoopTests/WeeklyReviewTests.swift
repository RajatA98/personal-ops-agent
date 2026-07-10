import XCTest
import SwiftData
import Core
import Data
import Goals
import Fixtures
@testable import DailyLoop

/// Phase 3B acceptance #4: the Weekly Review correctly categorizes a fixture set of tasks into
/// completed / slipped / next-week per goal.
final class WeeklyReviewTests: XCTestCase {

    func test_categorizesCompletedSlippedAndNextWeekPerGoal() throws {
        let ctx = try DL.context()

        // Completed: done, window earlier this week.
        let completed = DL.task(title: "Completed swim",
                                earliest: DL.now.addingTimeInterval(-2 * DL.day),
                                latest: DL.now.addingTimeInterval(-2 * DL.day + DL.hour),
                                complete: true)
        // Slipped: past window this week, no completion evidence.
        let slipped = DL.task(title: "Slipped ride",
                              earliest: DL.now.addingTimeInterval(-3 * DL.day),
                              latest: DL.now.addingTimeInterval(-3 * DL.day + DL.hour))
        // Next week: incomplete, window in the coming week.
        let upcoming = DL.task(title: "Upcoming brick",
                               earliest: DL.now.addingTimeInterval(3 * DL.day),
                               latest: DL.now.addingTimeInterval(3 * DL.day + DL.hour))

        let goal = try DL.insertGoal(into: ctx, tasks: [completed, slipped, upcoming])

        let review = WeeklyReviewAssembler().assemble(
            now: DL.now,
            goals: [BriefingGoalInput(goal: goal)],
            degradedSources: [DL.absentGmail()])

        XCTAssertEqual(review.goals.count, 1)
        let rollup = review.goals[0]
        XCTAssertEqual(rollup.completed.map(\.title), ["Completed swim"])
        XCTAssertEqual(rollup.slipped.map(\.title), ["Slipped ride"])
        XCTAssertEqual(rollup.nextWeek.map(\.title), ["Upcoming brick"])

        // Degraded sources explicitly noted (PRD: weekly review runs even if a source degraded).
        XCTAssertEqual(review.degradedSources.map(\.source), [.gmail])

        // Structured value serializes for Phase 5.
        let data = try JSONEncoder().encode(review)
        XCTAssertEqual(try JSONDecoder().decode(WeeklyReview.self, from: data), review)
    }
}
