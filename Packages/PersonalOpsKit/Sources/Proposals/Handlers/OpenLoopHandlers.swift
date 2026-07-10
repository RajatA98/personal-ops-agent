import Foundation
import Core
import Data

/// Defers an `OpenLoop` until a later date by setting its `snoozedUntil`. Nothing is created
/// or removed — the loop simply drops out of "active now" views until the date passes.
public struct SnoozeOpenLoopHandler: ProposalHandler {
    public let handledType: ProposalType = .snoozeOpenLoop
    public init() {}

    public func execute(_ proposal: Proposal, grant: ApprovalGrant,
                        context: HandlerContext) async throws -> ExecutionReceipt {
        let payload = try ProposalPayloadCoder.decode(SnoozeOpenLoopPayload.self, from: proposal.payload)
        guard let loop = try context.fetch(OpenLoop.self, appID: payload.openLoopAppID, keyPath: { $0.appID })
        else { throw ProposalError.targetNotFound }

        loop.snoozedUntil = payload.snoozeUntil
        loop.updatedAt = context.clock.now
        try context.context.save()

        return ExecutionReceipt(proposalAppID: proposal.appID, type: handledType,
                                summary: "Snoozed \"\(loop.title)\"")
    }
}

/// Marks a flagged signal (an `OpenLoop`) resolved — the agent proposed it as noise or
/// no-longer-relevant and the user agreed. Distinct from the user *dismissing the proposal
/// itself* (which never runs a handler): this executes an approved decision to resolve the loop.
public struct DismissSignalHandler: ProposalHandler {
    public let handledType: ProposalType = .dismissSignal
    public init() {}

    public func execute(_ proposal: Proposal, grant: ApprovalGrant,
                        context: HandlerContext) async throws -> ExecutionReceipt {
        let payload = try ProposalPayloadCoder.decode(DismissSignalPayload.self, from: proposal.payload)
        guard let loop = try context.fetch(OpenLoop.self, appID: payload.openLoopAppID, keyPath: { $0.appID })
        else { throw ProposalError.targetNotFound }

        loop.isResolved = true
        loop.updatedAt = context.clock.now
        try context.context.save()

        return ExecutionReceipt(proposalAppID: proposal.appID, type: handledType,
                                summary: "Dismissed \"\(loop.title)\"")
    }
}
