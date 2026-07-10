import Foundation
import Core

/// Per-type confirmation copy for the Ops Inbox. Each `ProposalType` gets its **own** action
/// verb and confirmation sentence — approving is never a generic "OK", it names exactly the
/// one action that will run (PRD: "each type has its own execution handler and confirmation
/// copy; approving executes only that Proposal's described action"). These strings are what
/// the Inbox renders on the approve button and in the confirmation line.
public struct ProposalConfirmationCopy: Equatable, Sendable {
    /// The label on the primary (approve) button, e.g. "Schedule", "Remember".
    public let actionVerb: String
    /// One-line description of exactly what approval will do.
    public let confirmation: String

    public init(actionVerb: String, confirmation: String) {
        self.actionVerb = actionVerb
        self.confirmation = confirmation
    }

    /// The copy for a given proposal type. Total over the closed `ProposalType` set.
    public static func copy(for type: ProposalType) -> ProposalConfirmationCopy {
        switch type {
        case .rememberFact:
            return .init(actionVerb: "Remember",
                         confirmation: "Save this to memory. Nothing else changes.")
        case .createAgentCalendarEvent:
            return .init(actionVerb: "Schedule",
                         confirmation: "Add this to your agent calendar (never your real calendar).")
        case .updateAgentCalendarEvent:
            return .init(actionVerb: "Update event",
                         confirmation: "Change this agent-calendar event. No other event is touched.")
        case .modifyGoalPlan:
            return .init(actionVerb: "Update plan",
                         confirmation: "Adjust this goal task. Your other tasks are unchanged.")
        case .markGoalProgress:
            return .init(actionVerb: "Log progress",
                         confirmation: "Record this progress. It does not complete anything else.")
        case .snoozeOpenLoop:
            return .init(actionVerb: "Snooze",
                         confirmation: "Hide this open loop until the chosen date.")
        case .dismissSignal:
            return .init(actionVerb: "Dismiss signal",
                         confirmation: "Mark this flagged item as resolved. Nothing is created.")
        }
    }
}
