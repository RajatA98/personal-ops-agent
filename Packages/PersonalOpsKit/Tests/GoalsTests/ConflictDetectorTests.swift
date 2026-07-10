import XCTest
import Core
import Data
@testable import Goals

/// Phase 4C acceptance #1: cross-goal conflict detection has fixture coverage for fixed/fixed,
/// fixed/movable, and movable/optional task pairs, correctly applying block/warn/allow per the
/// configured `ConflictPolicy`. Detection is pure and deterministic — no model container needed.
final class ConflictDetectorTests: XCTestCase {

    private let detector = ConflictDetector()
    private let t0 = Date(timeIntervalSince1970: 100 * 86_400)
    private let goalA = UUID()
    private let goalB = UUID()

    /// Two blocks that overlap by construction (B starts 30 min into A's hour), on distinct goals.
    private func pair(
        aFlex: TaskFlexibility, aPolicy: ConflictPolicy, aPriority: Int = 0,
        bFlex: TaskFlexibility, bPolicy: ConflictPolicy, bPriority: Int = 0,
        overlapping: Bool = true
    ) -> [ScheduledBlock] {
        let a = ScheduledBlock(
            taskAppID: UUID(), goalID: goalA, goalTitle: "Training", title: "Dawn swim",
            start: t0, end: t0.addingTimeInterval(3600),
            flexibility: aFlex, priority: aPriority, conflictPolicy: aPolicy)
        let bStart = overlapping ? t0.addingTimeInterval(1800) : t0.addingTimeInterval(7200)
        let b = ScheduledBlock(
            taskAppID: UUID(), goalID: goalB, goalTitle: "Job Search", title: "Interview prep",
            start: bStart, end: bStart.addingTimeInterval(3600),
            flexibility: bFlex, priority: bPriority, conflictPolicy: bPolicy)
        return [a, b]
    }

    // MARK: - The three named pairs

    /// fixed/fixed (block + block) → HARD conflict.
    func test_fixedFixed_blockBlock_isHardConflict() {
        let conflicts = detector.detect(blocks: pair(
            aFlex: .fixed, aPolicy: .block, bFlex: .fixed, bPolicy: .block))
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.severity, .hard)
    }

    /// fixed/movable (block + warn) → HARD (strictest wins; the fixed anchor forces a hard flag).
    /// The movable/warn side is the one chosen to yield.
    func test_fixedMovable_blockWarn_isHardConflict_movableYields() {
        let blocks = pair(aFlex: .fixed, aPolicy: .block, bFlex: .movable, bPolicy: .warn)
        let conflicts = detector.detect(blocks: blocks)
        XCTAssertEqual(conflicts.count, 1)
        let c = try! XCTUnwrap(conflicts.first)
        XCTAssertEqual(c.severity, .hard)
        XCTAssertEqual(c.anchor.conflictPolicy, .block)   // fixed anchor holds
        XCTAssertEqual(c.yielding.conflictPolicy, .warn)  // movable one moves
        XCTAssertEqual(c.yielding.flexibility, .movable)
    }

    /// movable/optional (warn + allow) → WARNING (no block involved; strictest is warn).
    func test_movableOptional_warnAllow_isWarning() {
        let conflicts = detector.detect(blocks: pair(
            aFlex: .movable, aPolicy: .warn, bFlex: .optional, bPolicy: .allow))
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.severity, .warning)
        // The optional/allow block is the natural one to move.
        XCTAssertEqual(conflicts.first?.yielding.flexibility, .optional)
    }

    // MARK: - Boundaries

    /// allow/allow → NOT flagged (both sides permit the overlap).
    func test_allowAllow_notFlagged() {
        let conflicts = detector.detect(blocks: pair(
            aFlex: .optional, aPolicy: .allow, bFlex: .optional, bPolicy: .allow))
        XCTAssertTrue(conflicts.isEmpty)
    }

    /// Non-overlapping blocks are never flagged, regardless of policy.
    func test_noOverlap_notFlagged() {
        let conflicts = detector.detect(blocks: pair(
            aFlex: .fixed, aPolicy: .block, bFlex: .fixed, bPolicy: .block, overlapping: false))
        XCTAssertTrue(conflicts.isEmpty)
    }

    /// Back-to-back (adjacent) blocks do not overlap.
    func test_adjacentBlocks_notFlagged() {
        let a = ScheduledBlock(taskAppID: UUID(), goalID: goalA, goalTitle: "A", title: "A",
            start: t0, end: t0.addingTimeInterval(3600),
            flexibility: .fixed, priority: 0, conflictPolicy: .block)
        let b = ScheduledBlock(taskAppID: UUID(), goalID: goalB, goalTitle: "B", title: "B",
            start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(7200),
            flexibility: .fixed, priority: 0, conflictPolicy: .block)
        XCTAssertTrue(detector.detect(blocks: [a, b]).isEmpty)
    }

    /// Same-goal overlaps are ignored — conflict detection is strictly cross-goal.
    func test_sameGoal_overlap_ignored() {
        let a = ScheduledBlock(taskAppID: UUID(), goalID: goalA, goalTitle: "A", title: "swim",
            start: t0, end: t0.addingTimeInterval(3600),
            flexibility: .fixed, priority: 0, conflictPolicy: .block)
        let b = ScheduledBlock(taskAppID: UUID(), goalID: goalA, goalTitle: "A", title: "bike",
            start: t0.addingTimeInterval(1800), end: t0.addingTimeInterval(5400),
            flexibility: .fixed, priority: 0, conflictPolicy: .block)
        XCTAssertTrue(detector.detect(blocks: [a, b]).isEmpty)
    }

    // MARK: - Yielding selection & determinism

    /// When both sides are equally fixed/block, the lower-priority block is chosen to yield.
    func test_fixedFixed_lowerPriorityYields() {
        let a = ScheduledBlock(taskAppID: UUID(), goalID: goalA, goalTitle: "A", title: "high",
            start: t0, end: t0.addingTimeInterval(3600),
            flexibility: .fixed, priority: 10, conflictPolicy: .block)
        let b = ScheduledBlock(taskAppID: UUID(), goalID: goalB, goalTitle: "B", title: "low",
            start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(4200),
            flexibility: .fixed, priority: 1, conflictPolicy: .block)
        let c = try! XCTUnwrap(detector.detect(blocks: [a, b]).first)
        XCTAssertEqual(c.yielding.title, "low")
        XCTAssertEqual(c.anchor.title, "high")
    }

    /// Detection is order-independent and produces a stable pair key.
    func test_detection_isDeterministic() {
        let blocks = pair(aFlex: .fixed, aPolicy: .block, bFlex: .movable, bPolicy: .warn)
        let forward = detector.detect(blocks: blocks)
        let reversed = detector.detect(blocks: blocks.reversed())
        XCTAssertEqual(forward.map { $0.pairKey }, reversed.map { $0.pairKey })
        XCTAssertEqual(forward.first?.severity, reversed.first?.severity)
    }

    // MARK: - GoalTask adapter (real Phase 3A metadata)

    /// The `GoalTask` adapter carries flexibility/priority/policy into detection, and completed
    /// or unscheduled tasks occupy no time.
    func test_goalTaskAdapter_flagsRealTrainingVsJobSearchOverlap() {
        let training = GoalTask(
            title: "Long ride", flexibility: .fixed, priority: 5,
            earliestAcceptable: t0, latestAcceptable: t0.addingTimeInterval(3600),
            expectedDuration: 3600, conflictPolicy: .block)
        let jobSearch = GoalTask(
            title: "Applications", flexibility: .movable, priority: 2,
            earliestAcceptable: t0.addingTimeInterval(1800), latestAcceptable: nil,
            expectedDuration: 3600, conflictPolicy: .warn)
        let done = GoalTask(
            title: "Done", flexibility: .movable,
            earliestAcceptable: t0, expectedDuration: 3600,
            conflictPolicy: .warn, isComplete: true)
        let unscheduled = GoalTask(
            title: "Someday", flexibility: .optional,
            earliestAcceptable: nil, expectedDuration: 3600, conflictPolicy: .allow)

        let blocks =
            ScheduledBlock.from(tasks: [training, done, unscheduled], goalID: goalA, goalTitle: "Training")
          + ScheduledBlock.from(tasks: [jobSearch], goalID: goalB, goalTitle: "Job Search")
        // done + unscheduled contribute no blocks.
        XCTAssertEqual(blocks.count, 2)

        let conflicts = detector.detect(blocks: blocks)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.severity, .hard)
        XCTAssertEqual(conflicts.first?.yielding.title, "Applications")
    }
}
