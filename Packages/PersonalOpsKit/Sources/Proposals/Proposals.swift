import Foundation
import Core

/// # Proposals module (the "propose, don't auto-act" execution layer) — Phase 4A
///
/// Implemented here:
///   • `ProposalEngine` — the Proposal status state machine; the single, structurally-enforced
///     path from a pending Proposal to execution (`ApprovalGrant` is un-forgeable outside it).
///   • Seven `ProposalHandler`s (one per `ProposalType`), each performing exactly its own
///     action with its own `ProposalConfirmationCopy`.
///   • Builders: `ScheduleProposalBuilder` (Phase 3A preview → create-event batch) and
///     `WeeklyReviewProposalBuilder` (Phase 3B weekly review → next-week batch), sharing one
///     idempotency-key seed (`GoalTask.appID`).
///   • `RejectionSignal`(+`Store`) — the "mark as wrong" record Phase 4B consumes.
///   • `IntegrationAlert` — reconnect-needed integrations surfaced as informational Inbox items.
///
/// The closed proposal vocabulary (`ProposalType`, `ProposalStatus`) lives in `Core`
/// (`Core/Vocabulary.swift`) so the persistence layer's `Proposal` model can store it without
/// a dependency cycle. Reference those types via `import Core`.
public enum ProposalsModule {}
