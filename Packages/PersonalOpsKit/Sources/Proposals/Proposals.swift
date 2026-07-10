import Foundation
import Core

/// # Proposals module (the "propose, don't auto-act" execution layer)
///
/// Phase 4A fills this in: the typed Proposal state machine, per-type execution handlers,
/// confirmation copy, and the Ops Inbox. Phase 0 fixes the closed set of proposal types
/// and lifecycle states so Phase 5's tool registry and Phase 3A's schedule previews map
/// to the same contract (AGENT_DESIGN §3). Adding a type later is a deliberate change here.
public enum ProposalType: String, Equatable, Sendable, Codable, CaseIterable {
    case rememberFact = "remember_fact"
    case createAgentCalendarEvent = "create_agent_calendar_event"
    case updateAgentCalendarEvent = "update_agent_calendar_event"
    case modifyGoalPlan = "modify_goal_plan"
    case markGoalProgress = "mark_goal_progress"
    case snoozeOpenLoop = "snooze_open_loop"
    case dismissSignal = "dismiss_signal"
}

/// Lifecycle states. Only `approved` ever triggers a handler; dismissed/snoozed/expired
/// never execute (the safety-critical negative cases tested in Phase 4A).
public enum ProposalStatus: String, Equatable, Sendable, Codable {
    case pending
    case approved
    case dismissed
    case snoozed
    case expired
}
