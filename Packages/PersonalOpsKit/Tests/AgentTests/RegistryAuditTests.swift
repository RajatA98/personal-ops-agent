import XCTest
import SwiftData
import Core
import Data
import Proposals
import Reasoning
import Fixtures
@testable import Agent

/// Fixture 5 (AGENT_DESIGN §6): pure registry audit — NO tool the LLM can call mutates the real
/// calendar/goals/memory directly. Every state-changing tool's only observable effect is a
/// pending Proposal. This is the structural proof behind Safety Rule #1.
@MainActor
final class RegistryAuditTests: XCTestCase {

    private func makeContext() throws -> (ModelContext, FakeGoogleCalendarAPI) {
        let ctx = try AgentTestSupport.context()
        return (ctx, FakeGoogleCalendarAPI())
    }

    private func registry(_ ctx: ModelContext, _ calendar: FakeGoogleCalendarAPI) -> ToolRegistry {
        ToolRegistry(ctx: ToolContext(
            context: ctx, clock: FakeClock(now: AgentTestSupport.refDate),
            calendar: calendar, gmail: nil, health: nil,
            engine: ProposalEngine(context: ctx, calendar: calendar)))
    }

    func test_registryHasExactlySixReadAndFivePropose() throws {
        let (ctx, cal) = try makeContext()
        let reg = registry(ctx, cal)
        XCTAssertEqual(reg.readToolNames.count, 6)
        XCTAssertEqual(reg.proposeToolNames.count, 5)
        XCTAssertEqual(Set(reg.readToolNames), [
            "search_memory", "get_goal_state", "search_calendar",
            "search_gmail", "get_health_summary", "get_daily_log"])
        XCTAssertEqual(Set(reg.proposeToolNames), [
            "propose_calendar_event", "propose_goal_plan_change", "propose_memory_fact",
            "propose_progress_mark", "propose_snooze"])
    }

    func test_everyProposeTool_onlyCreatesPendingProposal_neverMutatesRealState() async throws {
        let (ctx, cal) = try makeContext()
        let reg = registry(ctx, cal)
        let engine = ProposalEngine(context: ctx, clock: FakeClock(now: AgentTestSupport.refDate), calendar: cal)

        // Seed an open loop + goal task so the goal-plan / snooze tools have a target to reference.
        let loop = OpenLoop(factKey: "loop:x", title: "Follow up")
        ctx.insert(loop)
        try ctx.save()

        let calls: [ReasoningToolCall] = [
            .init(name: "propose_calendar_event",
                  argumentsJSON: #"{"title":"Block","start":"2026-08-01T09:00:00Z","end":"2026-08-01T10:00:00Z"}"#),
            .init(name: "propose_memory_fact", argumentsJSON: #"{"key":"coffee","value":"oat milk"}"#),
            .init(name: "propose_progress_mark", argumentsJSON: #"{"metric_key":"applications","value":3}"#),
            .init(name: "propose_goal_plan_change",
                  argumentsJSON: "{\"goal_task_id\":\"\(UUID().uuidString)\",\"mark_complete\":true}"),
            .init(name: "propose_snooze",
                  argumentsJSON: "{\"open_loop_id\":\"\(loop.appID.uuidString)\",\"snooze_until\":\"2026-09-01T00:00:00Z\"}")
        ]

        var receipts: [String] = []
        for call in calls {
            let (result, kind) = await reg.execute(call)
            XCTAssertEqual(kind, .propose)
            receipts.append(result)
        }

        // Each propose tool returned a pending receipt...
        for receipt in receipts {
            XCTAssertTrue(receipt.contains("pending_user_approval"), "receipt: \(receipt)")
        }
        // ...and produced exactly five PENDING proposals, with ZERO real calendar writes and no
        // execution (a mutation would require the un-forgeable ApprovalGrant, which no tool holds).
        let pending = try engine.pendingProposals()
        XCTAssertEqual(pending.count, calls.count)
        XCTAssertTrue(pending.allSatisfy { $0.status == .pending })
        XCTAssertEqual(cal.writeCallCount, 0, "no propose tool may write the real calendar")
    }

    func test_readTools_areClassifiedRead_andDoNotEnqueue() async throws {
        let (ctx, cal) = try makeContext()
        let reg = registry(ctx, cal)
        let engine = ProposalEngine(context: ctx, clock: FakeClock(now: AgentTestSupport.refDate), calendar: cal)

        for name in reg.readToolNames {
            let tool = try XCTUnwrap(reg.tool(named: name))
            XCTAssertEqual(tool.kind, .read)
        }
        // Executing a read tool creates no proposal.
        _ = await reg.execute(.init(name: "search_memory", argumentsJSON: #"{"query":"x"}"#))
        XCTAssertEqual(try engine.pendingProposals().count, 0)
        XCTAssertEqual(cal.writeCallCount, 0)
    }
}
