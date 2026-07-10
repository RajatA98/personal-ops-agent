import Foundation
import Core
import Data

/// Corrects a `GoalTask` (a structural child of `Goal`, not an independently-revisioned
/// memory fact — Phase 1's contract: a task's "correction" is a plan modification, applied
/// in place then saved, never a memory revision). Only the payload's non-nil fields change.
public struct ModifyGoalPlanHandler: ProposalHandler {
    public let handledType: ProposalType = .modifyGoalPlan
    public init() {}

    public func execute(_ proposal: Proposal, grant: ApprovalGrant,
                        context: HandlerContext) async throws -> ExecutionReceipt {
        let payload = try ProposalPayloadCoder.decode(ModifyGoalPlanPayload.self, from: proposal.payload)

        guard let task = try context.fetch(GoalTask.self, appID: payload.goalTaskAppID, keyPath: { $0.appID })
        else { throw ProposalError.targetNotFound }

        if let t = payload.newTitle { task.title = t }
        if let e = payload.newEarliestAcceptable { task.earliestAcceptable = e }
        if let l = payload.newLatestAcceptable { task.latestAcceptable = l }
        if let d = payload.newExpectedDuration { task.expectedDuration = d }
        if let c = payload.markComplete { task.isComplete = c }
        task.updatedAt = context.clock.now
        try context.context.save()

        return ExecutionReceipt(proposalAppID: proposal.appID, type: handledType,
                                summary: "Updated plan task \"\(task.title)\"")
    }
}
