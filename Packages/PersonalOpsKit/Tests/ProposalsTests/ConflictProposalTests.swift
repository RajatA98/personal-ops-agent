import XCTest
import SwiftData
import Core
import Data
import Goals
import Integrations
import Fixtures
@testable import Proposals

/// Phase 4C: a detected cross-goal conflict becomes a *pending* Proposal describing the
/// collision (never a silent block), and approving it reschedules the yielding task via the
/// existing `modify_goal_plan` handler.
@MainActor
final class ConflictProposalTests: XCTestCase {

    private let goalA = UUID()
    private let goalB = UUID()

    private func overlappingBlocks() -> [ScheduledBlock] {
        let anchor = ScheduledBlock(
            taskAppID: UUID(), goalID: goalA, goalTitle: "Training", title: "Dawn swim",
            start: PX.now, end: PX.now.addingTimeInterval(3600),
            flexibility: .fixed, priority: 5, conflictPolicy: .block)
        let yielding = ScheduledBlock(
            taskAppID: UUID(), goalID: goalB, goalTitle: "Job Search", title: "Interview prep",
            start: PX.now.addingTimeInterval(1800), end: PX.now.addingTimeInterval(5400),
            flexibility: .movable, priority: 2, conflictPolicy: .warn)
        return [anchor, yielding]
    }

    func test_conflict_producesPendingModifyGoalPlanProposal() throws {
        let conflicts = ConflictDetector().detect(blocks: overlappingBlocks())
        XCTAssertEqual(conflicts.count, 1)

        let proposals = ConflictProposalBuilder().proposals(for: conflicts, now: PX.now)
        XCTAssertEqual(proposals.count, 1)
        let p = try XCTUnwrap(proposals.first)
        XCTAssertEqual(p.proposalType, .modifyGoalPlan)
        XCTAssertEqual(p.status, .pending)
        XCTAssertEqual(p.source, .inference)
        XCTAssertTrue(p.rationale.contains("Interview prep"))
        XCTAssertTrue(p.rationale.contains("Dawn swim"))
        // The proposal targets the yielding task.
        XCTAssertEqual(p.affectedAppID, conflicts.first?.yielding.taskAppID)
    }

    /// The conflict Proposal surfaces in the Inbox via the standard enqueue seam, and
    /// re-detecting the same pair does not stack a duplicate (stable pair `factKey`).
    func test_conflictProposal_enqueuesAndDedupes() throws {
        let ctx = try PX.context()
        let engine = ProposalEngine(context: ctx, clock: FakeClock(now: PX.now))
        let blocks = overlappingBlocks()

        let batch1 = ConflictProposalBuilder().detectAndBuild(
            acrossGoals: [(goalA, "Training", [blocks[0]]), (goalB, "Job Search", [blocks[1]])],
            now: PX.now)
        _ = try engine.enqueueBatch(batch1)
        XCTAssertEqual(try engine.pendingProposals().count, 1)

        // Re-run: same pair → same factKey → deduped, still exactly one pending.
        let batch2 = ConflictProposalBuilder().proposals(
            for: ConflictDetector().detect(blocks: blocks), now: PX.now)
        _ = try engine.enqueueBatch(batch2)
        XCTAssertEqual(try engine.pendingProposals().count, 1)
    }

    /// Approving the conflict Proposal reschedules the yielding GoalTask to after the anchor.
    func test_approvingConflictProposal_reschedulesYieldingTask() async throws {
        let ctx = try PX.context()
        let clock = FakeClock(now: PX.now)
        let store = MemoryStore(context: ctx, clock: clock)

        // Persist the yielding task so modify_goal_plan can find it by appID.
        let yieldingTask = GoalTask(
            title: "Interview prep", flexibility: .movable, priority: 2,
            earliestAcceptable: PX.now.addingTimeInterval(1800),
            latestAcceptable: PX.now.addingTimeInterval(5400),
            expectedDuration: 3600, conflictPolicy: .warn)
        let goal = Goal(title: "Job Search")
        goal.factKey = "goal:jobsearch"
        goal.tasks = [yieldingTask]
        try store.insert(goal)

        let anchor = ScheduledBlock(
            taskAppID: UUID(), goalID: goalA, goalTitle: "Training", title: "Dawn swim",
            start: PX.now, end: PX.now.addingTimeInterval(3600),
            flexibility: .fixed, priority: 5, conflictPolicy: .block)
        let yielding = ScheduledBlock(
            taskAppID: yieldingTask.appID, goalID: goalB, goalTitle: "Job Search",
            title: "Interview prep",
            start: PX.now.addingTimeInterval(1800), end: PX.now.addingTimeInterval(5400),
            flexibility: .movable, priority: 2, conflictPolicy: .warn)

        let conflicts = ConflictDetector().detect(blocks: [anchor, yielding])
        let proposals = ConflictProposalBuilder().proposals(for: conflicts, now: PX.now)
        let engine = ProposalEngine(context: ctx, clock: clock)
        for p in proposals { try engine.enqueue(p) }

        let originalStart = yieldingTask.earliestAcceptable
        _ = try await engine.approve(try XCTUnwrap(proposals.first))

        // The task moved to after the anchor ended (anchor.end + gap).
        XCTAssertNotEqual(yieldingTask.earliestAcceptable, originalStart)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(yieldingTask.earliestAcceptable),
            anchor.end)
    }
}
