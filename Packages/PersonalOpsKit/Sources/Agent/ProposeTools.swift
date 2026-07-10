import Foundation
import Core
import Data
import Proposals
import Reasoning

/// # Propose tools (AGENT_DESIGN §3, Phase 4A seam)
///
/// Each propose tool builds a typed payload and calls `ProposalEngine.enqueue` — the ONE thing
/// it can do. It cannot approve or execute: the `ApprovalGrant` handlers require is un-forgeable
/// (Phase 4A). So a confused or adversarial model's worst case is a **pending Proposal** in the
/// Ops Inbox — never a calendar write, a sent message, or a memory mutation. The registry-audit
/// fixture (§6 #5) asserts exactly this: the only observable side effect of a propose tool is a
/// pending Proposal.
///
/// The tool→ProposalType/payload mapping is the contract Phase 4A fixed:
///   propose_calendar_event   → create_agent_calendar_event (CreateAgentCalendarEventPayload)
///   propose_goal_plan_change  → modify_goal_plan            (ModifyGoalPlanPayload)
///   propose_memory_fact       → remember_fact               (RememberFactPayload)
///   propose_progress_mark     → mark_goal_progress          (MarkGoalProgressPayload)
///   propose_snooze            → snooze_open_loop             (SnoozeOpenLoopPayload)

/// A small, process-stable hash for deriving idempotency keys / factKeys from tool arguments,
/// so re-proposing the same thing collapses onto the existing pending item (FNV-1a; Swift's
/// built-in `Hasher` is per-process randomized and would break cross-launch dedupe).
enum StableHash {
    static func of(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// The receipt every propose tool returns to the transcript — makes it unambiguous to the model
/// that nothing happened yet and the item is awaiting the user.
private func receipt(_ proposal: Proposal) -> String {
    ToolJSON.string([
        "proposalId": proposal.appID.uuidString,
        "status": "pending_user_approval",
        "note": "A proposal was created and is waiting in the Ops Inbox for the user to approve. Nothing has been changed."
    ])
}

private extension [String: Any] {
    func str(_ key: String) -> String? { self[key] as? String }
    func dbl(_ key: String) -> Double? {
        if let d = self[key] as? Double { return d }
        if let i = self[key] as? Int { return Double(i) }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let s = self[key] as? String { return Bool(s) }
        return nil
    }
}

@MainActor
struct ProposeCalendarEventTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .propose

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "propose_calendar_event",
            description: "Propose a new event on the app's agent-owned calendar (title, ISO-8601 start and end). This does NOT create the event — it creates a pending proposal the user must approve in their Ops Inbox. Never writes to the user's real calendars.",
            parametersSchema: """
            {"type":"object","properties":{"title":{"type":"string"},"start":{"type":"string","description":"ISO-8601"},"end":{"type":"string","description":"ISO-8601"}},"required":["title","start","end"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        let args = call.arguments
        guard let title = args.str("title"),
              let start = ToolJSON.parseDate(args["start"]),
              let end = ToolJSON.parseDate(args["end"]) else {
            throw AppError.reasoning(.invalidResponse)
        }
        let idempotencyKey = "qa:" + StableHash.of("\(title)|\(ToolJSON.date(start))")
        let payload = CreateAgentCalendarEventPayload(title: title, start: start, end: end, idempotencyKey: idempotencyKey)
        let proposal = Proposal(
            factKey: "proposal:qa:create_event:\(idempotencyKey)",
            source: .reasoning,
            type: .createAgentCalendarEvent,
            status: .pending,
            rationale: "Add “\(title)” to your agent calendar.",
            payload: try ProposalPayloadCoder.encode(payload))
        let enqueued = try ctx.engine.enqueue(proposal)
        return receipt(enqueued)
    }
}

@MainActor
struct ProposeMemoryFactTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .propose

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "propose_memory_fact",
            description: "Propose remembering a fact/preference (a key and a value). Creates a pending proposal the user approves before it is saved to memory; it does not save anything on its own.",
            parametersSchema: """
            {"type":"object","properties":{"key":{"type":"string"},"value":{"type":"string"}},"required":["key","value"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        let args = call.arguments
        guard let key = args.str("key"), let value = args.str("value") else {
            throw AppError.reasoning(.invalidResponse)
        }
        let slug = StableHash.of(key.lowercased())
        let factKey = "preference:\(slug)"
        let payload = RememberFactPayload(factKey: factKey, key: key, value: value, confidence: 0.6)
        let proposal = Proposal(
            factKey: "proposal:qa:remember:\(slug)",
            source: .reasoning,
            type: .rememberFact,
            status: .pending,
            rationale: "Remember: \(key) = \(value)",
            payload: try ProposalPayloadCoder.encode(payload))
        return receipt(try ctx.engine.enqueue(proposal))
    }
}

@MainActor
struct ProposeProgressMarkTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .propose

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "propose_progress_mark",
            description: "Propose recording progress toward a goal (a metric key, a numeric value, an optional note and goal id). Creates a pending proposal; it does not record anything until the user approves.",
            parametersSchema: """
            {"type":"object","properties":{"metric_key":{"type":"string"},"value":{"type":"number"},"note":{"type":"string"},"goal_id":{"type":"string"}},"required":["metric_key","value"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        let args = call.arguments
        guard let metric = args.str("metric_key"), let value = args.dbl("value") else {
            throw AppError.reasoning(.invalidResponse)
        }
        let goalAppID = args.str("goal_id").flatMap(UUID.init(uuidString:))
        let note = args.str("note") ?? ""
        let progressFactKey = "goal_progress:qa:\(StableHash.of("\(metric)|\(value)|\(ToolJSON.date(ctx.clock.now))"))"
        let payload = MarkGoalProgressPayload(goalAppID: goalAppID, progressFactKey: progressFactKey,
                                              metricKey: metric, value: value, note: note)
        let proposal = Proposal(
            factKey: "proposal:qa:progress:\(StableHash.of(progressFactKey))",
            source: .reasoning,
            type: .markGoalProgress,
            status: .pending,
            rationale: "Record \(metric): \(value)\(note.isEmpty ? "" : " (\(note))").",
            payload: try ProposalPayloadCoder.encode(payload))
        return receipt(try ctx.engine.enqueue(proposal))
    }
}

@MainActor
struct ProposeGoalPlanChangeTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .propose

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "propose_goal_plan_change",
            description: "Propose a change to a goal task (identified by its task id): a new title, a new latest-acceptable time, and/or marking it complete. Creates a pending proposal; the plan is not changed until the user approves.",
            parametersSchema: """
            {"type":"object","properties":{"goal_task_id":{"type":"string"},"new_title":{"type":"string"},"new_latest_acceptable":{"type":"string","description":"ISO-8601"},"mark_complete":{"type":"boolean"}},"required":["goal_task_id"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        let args = call.arguments
        guard let taskID = args.str("goal_task_id").flatMap(UUID.init(uuidString:)) else {
            throw AppError.reasoning(.invalidResponse)
        }
        let payload = ModifyGoalPlanPayload(
            goalTaskAppID: taskID,
            newTitle: args.str("new_title"),
            newLatestAcceptable: ToolJSON.parseDate(args["new_latest_acceptable"]),
            markComplete: args.bool("mark_complete"))
        let proposal = Proposal(
            factKey: "proposal:qa:modify_plan:\(taskID.uuidString)",
            source: .reasoning,
            type: .modifyGoalPlan,
            status: .pending,
            rationale: "Update a task in your goal plan.",
            payload: try ProposalPayloadCoder.encode(payload))
        return receipt(try ctx.engine.enqueue(proposal))
    }
}

@MainActor
struct ProposeSnoozeTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .propose

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "propose_snooze",
            description: "Propose snoozing an open loop (by its id) until a later ISO-8601 time. Creates a pending proposal; the item is not snoozed until the user approves.",
            parametersSchema: """
            {"type":"object","properties":{"open_loop_id":{"type":"string"},"snooze_until":{"type":"string","description":"ISO-8601"}},"required":["open_loop_id","snooze_until"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        let args = call.arguments
        guard let loopID = args.str("open_loop_id").flatMap(UUID.init(uuidString:)),
              let until = ToolJSON.parseDate(args["snooze_until"]) else {
            throw AppError.reasoning(.invalidResponse)
        }
        let payload = SnoozeOpenLoopPayload(openLoopAppID: loopID, snoozeUntil: until)
        let proposal = Proposal(
            factKey: "proposal:qa:snooze:\(loopID.uuidString)",
            source: .reasoning,
            type: .snoozeOpenLoop,
            status: .pending,
            rationale: "Snooze this until \(ToolJSON.date(until)).",
            payload: try ProposalPayloadCoder.encode(payload))
        return receipt(try ctx.engine.enqueue(proposal))
    }
}
