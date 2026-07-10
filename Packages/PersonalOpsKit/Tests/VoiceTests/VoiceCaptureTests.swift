import XCTest
import SwiftData
import Core
import Data
import Goals
import DailyLoop
import Fixtures
@testable import Voice

@MainActor
final class VoiceCaptureTests: XCTestCase {

    // MARK: - Local seeding helpers

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    static let now = Date(timeIntervalSince1970: 10 * 86_400)

    private func task(_ title: String) -> GoalTask {
        GoalTask(createdAt: Self.now, updatedAt: Self.now, title: title, flexibility: .movable,
                 priority: 2, earliestAcceptable: Self.now, latestAcceptable: Self.now.addingTimeInterval(3600),
                 expectedDuration: 3600, conflictPolicy: .warn, isComplete: false)
    }

    private func seedGoal(_ ctx: ModelContext, tasks: [GoalTask]) throws -> Goal {
        let goal = Goal(source: .user, createdAt: Self.now, updatedAt: Self.now,
                        title: "Ironman 70.3", playbookKey: "training", status: .active)
        goal.factKey = "goal:ironman"
        goal.tasks = tasks
        try MemoryStore(context: ctx).insert(goal)
        return goal
    }

    // MARK: - Parser (pure, deterministic)

    func test_parser_classifiesDoneSkipAndNote() throws {
        let ctx = try DataStore.makeContainer(inMemory: true)
        let context = ModelContext(ctx)
        let swim = task("Pool swim")
        let strength = task("Strength session")
        let goal = try seedGoal(context, tasks: [swim, strength])
        let openTasks = [(goal: goal, task: swim), (goal: goal, task: strength)]

        let draft = VoiceCaptureParser().parse(
            transcript: "done with the pool swim and skipped strength, felt a bit tired",
            openTasks: openTasks)

        XCTAssertEqual(draft.completedTitles, ["Pool swim"])
        XCTAssertEqual(draft.skippedTitles, ["Strength session"])
        XCTAssertEqual(draft.note, "felt a bit tired")
        XCTAssertEqual(draft.input.completed.count, 1)
        XCTAssertEqual(draft.input.skipped.count, 1)
    }

    // A command that matches no real task falls through to the note (never guesses a task).
    func test_parser_unmatchedCommand_becomesNote() throws {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        let swim = task("Pool swim")
        let goal = try seedGoal(context, tasks: [swim])

        let draft = VoiceCaptureParser().parse(
            transcript: "finished the taxes",
            openTasks: [(goal: goal, task: swim)])

        XCTAssertTrue(draft.completedTitles.isEmpty)
        XCTAssertEqual(draft.note, "finished the taxes")
    }

    // Determinism: same input → same output.
    func test_parser_isDeterministic() throws {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        let swim = task("Pool swim")
        let goal = try seedGoal(context, tasks: [swim])
        let openTasks = [(goal: goal, task: swim)]
        let parser = VoiceCaptureParser()
        let a = parser.parse(transcript: "done with pool swim", openTasks: openTasks)
        let b = parser.parse(transcript: "done with pool swim", openTasks: openTasks)
        XCTAssertEqual(a.completedTitles, b.completedTitles)
        XCTAssertEqual(a.note, b.note)
    }

    // MARK: - Controller flow

    // ACCEPTANCE: voice-driven Evening Capture completes in a single interaction for the common
    // case — record once → confirm → applied.
    func test_singleInteraction_recordConfirmApplied() async throws {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        let swim = task("Pool swim")
        let goal = try seedGoal(context, tasks: [swim])
        let store = MemoryStore(context: context)
        let controller = VoiceCaptureController(
            stt: FakeSpeechToText(Transcription(text: "done with the pool swim, good session", confidence: 0.9)),
            store: store, calendar: Self.utc)

        await controller.captureTurn(openTasks: [(goal: goal, task: swim)])

        // One review step is presented; nothing persisted yet.
        guard case .reviewing = controller.state else {
            return XCTFail("expected .reviewing, got \(controller.state)")
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyLog>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GoalProgress>()), 0)

        // The single confirmation applies it.
        let result = controller.confirm(now: Self.now)

        XCTAssertEqual(result?.completedCount, 1)
        XCTAssertTrue(swim.isComplete)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyLog>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GoalProgress>()), 1)
        guard case .applied = controller.state else {
            return XCTFail("expected .applied, got \(controller.state)")
        }
    }

    // ACCEPTANCE / PRIVACY: nothing persists before confirmation, and cancelling writes nothing —
    // the transcript is never stored unless the capture is confirmed.
    func test_nothingPersistsBeforeConfirmation() async throws {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        let swim = task("Pool swim")
        let goal = try seedGoal(context, tasks: [swim])
        let controller = VoiceCaptureController(
            stt: FakeSpeechToText(Transcription(text: "done with the pool swim", confidence: 0.9)),
            store: MemoryStore(context: context), calendar: Self.utc)

        await controller.captureTurn(openTasks: [(goal: goal, task: swim)])
        // No confirmation → cancel.
        controller.cancel()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyLog>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GoalProgress>()), 0)
        XCTAssertFalse(swim.isComplete)
    }

    // A low-confidence capture transcript is flagged in the review step (but the confirm gate
    // already protects the write).
    func test_lowConfidenceCapture_flaggedInReview() async throws {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        let swim = task("Pool swim")
        let goal = try seedGoal(context, tasks: [swim])
        let controller = VoiceCaptureController(
            stt: FakeSpeechToText(Transcription(text: "done with the pool swim", confidence: 0.3)),
            store: MemoryStore(context: context), calendar: Self.utc)

        await controller.captureTurn(openTasks: [(goal: goal, task: swim)])

        guard case let .reviewing(_, lowConfidence) = controller.state else {
            return XCTFail("expected .reviewing, got \(controller.state)")
        }
        XCTAssertTrue(lowConfidence)
    }
}
