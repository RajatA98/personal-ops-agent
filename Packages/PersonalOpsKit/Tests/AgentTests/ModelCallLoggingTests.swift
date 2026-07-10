import XCTest
import SwiftData
import Core
import Data
import DailyLoop
import Reasoning
import Fixtures
@testable import Agent

/// Model-call logging test (Phase 5 acceptance): required metadata is persisted per round, and
/// tokens/headers are NEVER logged (Safety Rule #5, AGENT_DESIGN §2).
@MainActor
final class ModelCallLoggingTests: XCTestCase {

    func test_briefingNarration_recordsRequiredMetadata() async throws {
        let audit = InMemoryModelCallAuditSink()
        let narrator = BriefingNarrator(provider: FakeReasoningProvider(scriptedText: "narrative"),
                                        audit: audit, clock: FakeClock(now: AgentTestSupport.refDate))
        _ = try await narrator.narrate(AgentTestSupport.briefingFixture())

        let record = try XCTUnwrap(audit.audits.first)
        XCTAssertEqual(record.purpose, .morningBriefing)
        XCTAssertEqual(record.provider, "fake")
        XCTAssertFalse(record.includedRawExternalContent)
        XCTAssertFalse(record.inputCategories.isEmpty)
        XCTAssertEqual(record.roundCount, 1)
    }

    func test_qaLoop_logsEveryRound_withToolNamesAndArgs() async throws {
        let ctx = try AgentTestSupport.context()
        AgentTestSupport.seedGoal(ctx, title: "Job search", playbook: "job_search")
        let audit = InMemoryModelCallAuditSink()
        let script: [ReasoningResponse] = [
            ReasoningResponse(text: nil, toolCalls: [
                ReasoningToolCall(name: "get_goal_state", argumentsJSON: "{}")]),
            ReasoningResponse(text: "You're on your job search.")
        ]
        let env = AgentEnvironment.with(provider: ScriptedReasoningProvider(script: script),
                                        audit: audit, clock: FakeClock(now: AgentTestSupport.refDate))
        let qa = try XCTUnwrap(env.qaOrchestrator(context: ctx))
        _ = try await qa.answer(question: "What am I working on?")

        XCTAssertEqual(audit.audits.count, 2, "one audit per model round")
        XCTAssertTrue(audit.audits[0].toolCallsRequested.contains { $0.contains("get_goal_state") })
        XCTAssertTrue(audit.audits.allSatisfy { $0.purpose == .qanda })
        XCTAssertEqual(audit.audits[1].roundCount, 2)
    }

    func test_auditSchema_carriesNoTokensOrHeaders() throws {
        // The persisted audit record encodes to JSON with no token/header/authorization/apikey.
        let audit = ModelCallAudit(
            timestamp: AgentTestSupport.refDate,
            purpose: .qanda,
            inputCategories: [.userMessage, .memory],
            provider: "gemini:gemini-2.0-flash",
            includedRawExternalContent: false,
            toolCallsRequested: ["search_memory {\"query\":\"dentist\"}"],
            roundCount: 1)
        let data = try JSONEncoder().encode(audit)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["authorization", "bearer", "apikey", "api_key", "token", "aiza", "?key="] {
            XCTAssertFalse(json.contains(forbidden), "audit JSON leaked '\(forbidden)': \(json)")
        }
    }

    func test_loggingSink_redactsAnyKeyShapedValue() {
        // Even if an arg summary somehow carried a key-shaped value, the RedactingLogger scrubs it.
        var logger = RedactingLogger(category: "test")
        logger.registerSecret("AIzaSECRET_KEY_VALUE_1234567890")
        let redacted = logger.redact("model-call tools=[search_memory AIzaSECRET_KEY_VALUE_1234567890]")
        XCTAssertFalse(redacted.contains("AIzaSECRET_KEY_VALUE_1234567890"))
    }
}
