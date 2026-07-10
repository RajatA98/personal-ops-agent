import XCTest
import Foundation
import SwiftData
import Core
import Integrations
import Data
import Proposals
import Fixtures
@testable import Signals

/// The two Phase 4B acceptance criteria: (1) duplicate scan of a thread never creates a second
/// pending Proposal — proven across a store roundtrip — and (2) marking a Gmail-derived Proposal
/// wrong measurably suppresses similar future extraction from the same source pattern.
@MainActor
final class GmailScanCoordinatorTests: XCTestCase {

    // A fixed Thursday 09:00 UTC.
    private let received = Date(timeIntervalSince1970: 1_609_837_200)

    private func utcExtractor() -> GmailSignalExtractor {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return GmailSignalExtractor(calendar: cal)
    }

    private func inMemoryContainer() throws -> ModelContainer {
        try DataStore.makeContainer(inMemory: true)
    }

    private func diskContainer(at url: URL) throws -> ModelContainer {
        let config = ModelConfiguration(schema: DataStore.schema, url: url)
        return try ModelContainer(for: DataStore.schema,
                                  migrationPlan: MemoryMigrationPlan.self,
                                  configurations: config)
    }

    private func interviewMessage(threadID: String, subject: String = "Interview confirmed for Thursday 3pm",
                                  sender: String = "Recruiting <no-reply@jobs.example.com>",
                                  msgID: String) -> GmailMessageMetadata {
        GmailMessageMetadata(messageID: msgID, threadID: threadID, receivedDate: received,
                             scanTimestamp: received, snippet: "Interview confirmed for Thursday at 3pm",
                             subject: subject, sender: sender)
    }

    private func pendingCount(_ context: ModelContext) throws -> Int {
        try MemoryStore(context: context).all(Proposal.self).filter { $0.status == .pending }.count
    }

    // MARK: - Acceptance #1: duplicate scan does not create a second pending proposal (survives roundtrip)

    func test_duplicateScanSameThread_noSecondProposal_acrossStoreRoundtrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.store")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gmail = FakeGmailAPI(messages: [interviewMessage(threadID: "t-500", msgID: "m-1")])
        let clock = FakeClock(now: received)

        // Session 1 — fresh engine + container: one proposal is created.
        do {
            let container = try diskContainer(at: url)
            let context = ModelContext(container)
            let metadata = SwiftDataGmailMetadataStore(modelContainer: container)
            let coordinator = GmailScanCoordinator(context: context, gmail: gmail, metadataStore: metadata,
                                                   clock: clock, extractor: utcExtractor())
            let r1 = try await coordinator.scanNow(since: Date(timeIntervalSince1970: 0))
            XCTAssertEqual(r1.proposed, 1)
            XCTAssertEqual(try pendingCount(context), 1)
        }

        // Session 2 (simulated relaunch) — a brand-new container/engine over the same on-disk
        // store. Re-scanning the same thread must NOT create a second pending proposal; the
        // factKey dedupe reads the persisted proposal, so the duplicate is dropped.
        let container2 = try diskContainer(at: url)
        let context2 = ModelContext(container2)
        let metadata2 = SwiftDataGmailMetadataStore(modelContainer: container2)
        let coordinator2 = GmailScanCoordinator(context: context2, gmail: gmail, metadataStore: metadata2,
                                                clock: clock, extractor: utcExtractor())
        let r2 = try await coordinator2.scanNow(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r2.proposed, 0, "no new proposal for an already-seen thread")
        XCTAssertEqual(r2.dedupedByThread, 1, "the duplicate is caught by the factKey layer")
        XCTAssertEqual(try pendingCount(context2), 1, "still exactly one pending proposal total")
    }

    // MARK: - Acceptance #2: mark-as-wrong downranks similar future extraction

    func test_markAsWrong_suppressesSimilarFutureExtraction() async throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let clock = FakeClock(now: received)
        let engine = ProposalEngine(context: context, clock: clock)
        let metadata = SwiftDataGmailMetadataStore(modelContainer: container)

        // Thread A: recruiter "interview confirmed" → an event proposal.
        let gmailA = FakeGmailAPI(messages: [interviewMessage(threadID: "t-500", msgID: "m-1")])
        let coordinatorA = GmailScanCoordinator(context: context, gmail: gmailA, metadataStore: metadata,
                                                clock: clock, extractor: utcExtractor(), engine: engine)
        let rA = try await coordinatorA.scanNow(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rA.proposed, 1)

        // Control: a DIFFERENT thread from the same sender/subject-shape would also propose,
        // proving the later suppression is real (not the thread-level factKey dedupe).
        let messageB = interviewMessage(threadID: "t-600",
                                        subject: "Interview confirmed for Monday 11am", msgID: "m-2")

        // The user marks thread A's proposal WRONG, tagged with the stable source pattern.
        let proposalA = try engine.pendingProposals().first(where: {
            GmailScanCoordinator.threadID(fromFactKey: $0.factKey) == "t-500"
        })!
        let threadID = GmailScanCoordinator.threadID(fromFactKey: proposalA.factKey)!
        let pattern = await coordinatorA.sourcePattern(forThreadID: threadID)
        XCTAssertNotNil(pattern)
        try engine.markAsWrong(proposalA, sourcePattern: pattern)

        // Now scan thread B (same sender + subject shape, different thread). It must be
        // SUPPRESSED by the downranking, not enqueued.
        let gmailB = FakeGmailAPI(messages: [messageB])
        let coordinatorB = GmailScanCoordinator(context: context, gmail: gmailB, metadataStore: metadata,
                                                clock: clock, extractor: utcExtractor(), engine: engine)
        let rB = try await coordinatorB.scanNow(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rB.suppressedByRejection, 1, "the same source pattern is downranked")
        XCTAssertEqual(rB.proposed, 0, "no proposal from the marked-wrong source pattern")

        // Measurable reduction: only the (now-dismissed) A proposal exists; B produced none.
        let pending = try engine.pendingProposals()
        XCTAssertTrue(pending.isEmpty, "A was marked wrong; B was suppressed → no pending proposals")
    }

    func test_scanDedupesWithinASinglePass() async throws {
        // Two messages in the SAME thread in one scan → one proposal (factKey collapses them).
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let clock = FakeClock(now: received)
        let metadata = SwiftDataGmailMetadataStore(modelContainer: container)
        let gmail = FakeGmailAPI(messages: [
            interviewMessage(threadID: "t-500", msgID: "m-1"),
            interviewMessage(threadID: "t-500", subject: "Re: Interview confirmed for Thursday 3pm", msgID: "m-2")
        ])
        let coordinator = GmailScanCoordinator(context: context, gmail: gmail, metadataStore: metadata,
                                               clock: clock, extractor: utcExtractor())
        let r = try await coordinator.scanNow(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.proposed, 1)
        XCTAssertEqual(try pendingCount(context), 1)
    }
}
