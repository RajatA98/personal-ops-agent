import Foundation
import Core
import Data
import Reasoning

/// The fixed tool registry (AGENT_DESIGN §3): 6 read tools + 5 propose tools. Read tools execute
/// immediately and are side-effect-free; propose tools only ever enqueue a pending Proposal. The
/// registry exposes the provider-neutral declarations handed to the model and dispatches a
/// requested call to its tool. There is no third class of tool — a tool is `.read` or `.propose`.
@MainActor
public struct ToolRegistry {
    public let tools: [any AgentTool]
    private let byName: [String: any AgentTool]

    public init(ctx: ToolContext) {
        self.tools = [
            // Read (execute immediately, side-effect-free)
            SearchMemoryTool(ctx: ctx),
            GetGoalStateTool(ctx: ctx),
            SearchCalendarTool(ctx: ctx),
            SearchGmailTool(ctx: ctx),
            GetHealthSummaryTool(ctx: ctx),
            GetDailyLogTool(ctx: ctx),
            // Propose (create a pending Proposal; never execute)
            ProposeCalendarEventTool(ctx: ctx),
            ProposeGoalPlanChangeTool(ctx: ctx),
            ProposeMemoryFactTool(ctx: ctx),
            ProposeProgressMarkTool(ctx: ctx),
            ProposeSnoozeTool(ctx: ctx)
        ]
        var map: [String: any AgentTool] = [:]
        for tool in tools { map[tool.declaration.name] = tool }
        self.byName = map
    }

    /// Provider-neutral declarations to offer the model.
    public var declarations: [ReasoningTool] { tools.map(\.declaration) }

    public var readToolNames: [String] { tools.filter { $0.kind == .read }.map { $0.declaration.name } }
    public var proposeToolNames: [String] { tools.filter { $0.kind == .propose }.map { $0.declaration.name } }

    public func tool(named name: String) -> (any AgentTool)? { byName[name] }

    /// Execute a requested tool call, returning its JSON result string. An unknown tool returns
    /// an error result (never a crash) so a confused model degrades gracefully.
    public func execute(_ call: ReasoningToolCall) async -> (result: String, kind: ToolKind?) {
        guard let tool = byName[call.name] else {
            return (ToolJSON.string(["error": "Unknown tool: \(call.name)"]), nil)
        }
        do {
            return (try await tool.execute(call), tool.kind)
        } catch {
            return (ToolJSON.string(["error": "Tool \(call.name) failed."]), tool.kind)
        }
    }
}
