import Foundation
import Core
import Data
import Goals

/// # ConflictProposalBuilder — a detected cross-goal conflict → a review Proposal
///
/// Phase 4C's integration seam. `ConflictDetector` (in Goals) finds overlaps deterministically;
/// this builder turns each into a **pending Proposal describing the collision**, so it surfaces
/// in the Ops Inbox rather than silently blocking or double-booking (PRD Conflict Detection).
///
/// The Proposal offers a concrete, approvable resolution: reschedule the *yielding* block (the
/// more movable / lower-priority side the detector picked) to just after the anchor block ends.
/// This reuses the existing `modify_goal_plan` type/handler — no new `ProposalType` is minted
/// (Safety Rule #1: adding an action type is a deliberate vocabulary change, not a side effect).
/// Approving reschedules; dismissing leaves the plan as-is; either way nothing happens without
/// the user (a hard fixed/fixed collision the user must untangle manually is described in the
/// rationale, with the lower-priority side offered as the move candidate).
///
/// `factKey` is the order-independent conflict pair key, so re-running detection over the same
/// two tasks reuses `enqueueBatch`'s active-factKey dedupe and never stacks duplicate proposals.
public struct ConflictProposalBuilder {
    public init() {}

    /// A small gap left after the anchor block before the rescheduled yielding block starts.
    private static let gap: TimeInterval = 15 * 60

    /// Build one `modify_goal_plan` Proposal per conflict. `expiresAfter` drops a stale conflict
    /// proposal (default 14 days) if never acted on.
    public func proposals(
        for conflicts: [ScheduleConflict],
        now: Date,
        expiresAfter: TimeInterval? = 14 * 86_400
    ) -> [Proposal] {
        conflicts.map { conflict in build(conflict, now: now, expiresAfter: expiresAfter) }
    }

    /// Convenience: detect across goals and build the resulting proposals in one call. This is
    /// the seam a scheduling flow uses right before it enqueues a batch of create-event
    /// proposals — surface any collision alongside the schedule instead of writing over it.
    public func detectAndBuild(
        acrossGoals groups: [(goalID: UUID, goalTitle: String, blocks: [ScheduledBlock])],
        now: Date,
        detector: ConflictDetector = ConflictDetector(),
        expiresAfter: TimeInterval? = 14 * 86_400
    ) -> [Proposal] {
        proposals(for: detector.detect(acrossGoals: groups), now: now, expiresAfter: expiresAfter)
    }

    private func build(_ conflict: ScheduleConflict, now: Date, expiresAfter: TimeInterval?) -> Proposal {
        let yielding = conflict.yielding
        let anchor = conflict.anchor
        let duration = yielding.end.timeIntervalSince(yielding.start)
        let newStart = anchor.end.addingTimeInterval(Self.gap)
        let newLatest = newStart.addingTimeInterval(duration)

        let payload = ModifyGoalPlanPayload(
            goalTaskAppID: yielding.taskAppID,
            newEarliestAcceptable: newStart,
            newLatestAcceptable: newLatest)

        let severityNote: String
        switch conflict.severity {
        case .hard:
            if anchor.conflictPolicy == .block && yielding.conflictPolicy == .block {
                severityNote = "Both are fixed anchors — review manually; the lower-priority block is offered as the one to move."
            } else {
                severityNote = "\"\(anchor.title)\" is a fixed anchor, so \"\(yielding.title)\" is the one to move."
            }
        case .warning:
            severityNote = "Neither is fixed — this is a heads-up you can keep or reschedule."
        }

        let rationale =
            "\"\(yielding.title)\" (\(yielding.goalTitle)) overlaps \"\(anchor.title)\" (\(anchor.goalTitle)). "
            + severityNote
            + " Proposes moving \"\(yielding.title)\" to just after \"\(anchor.title)\" ends."

        let proposal = Proposal(
            source: .inference,
            confidence: conflict.severity == .hard ? 0.9 : 0.6,
            createdAt: now,
            updatedAt: now,
            expiresAt: expiresAfter.map { now.addingTimeInterval($0) },
            type: .modifyGoalPlan,
            status: .pending,
            rationale: rationale,
            payload: (try? ProposalPayloadCoder.encode(payload)) ?? "",
            affectedAppID: yielding.taskAppID)
        proposal.factKey = "proposal:conflict:\(conflict.pairKey)"
        return proposal
    }
}
