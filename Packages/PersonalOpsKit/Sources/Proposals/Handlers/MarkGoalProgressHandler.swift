import Foundation
import Core
import Data

/// Appends one `GoalProgress` entry (an append log — each entry is its own memory fact with a
/// fresh `factKey`). Links it to its goal when the payload names one. Does **not** complete a
/// task or touch anything else (the "only its own action" guarantee, per PRD).
public struct MarkGoalProgressHandler: ProposalHandler {
    public let handledType: ProposalType = .markGoalProgress
    public init() {}

    public func execute(_ proposal: Proposal, grant: ApprovalGrant,
                        context: HandlerContext) async throws -> ExecutionReceipt {
        let payload = try ProposalPayloadCoder.decode(MarkGoalProgressPayload.self, from: proposal.payload)

        let goal = try payload.goalAppID.flatMap {
            try context.fetch(Goal.self, appID: $0, keyPath: { $0.appID })
        }

        let entry = GoalProgress(source: .user,
                                 createdAt: context.clock.now, updatedAt: context.clock.now,
                                 metricKey: payload.metricKey, value: payload.value,
                                 note: payload.note, goal: goal)
        entry.factKey = payload.progressFactKey
        try context.store.insert(entry)

        return ExecutionReceipt(proposalAppID: proposal.appID, type: handledType,
                                summary: "Logged \(payload.metricKey) = \(payload.value)")
    }
}
