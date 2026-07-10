import Foundation
import Core
import Data

/// Persists a `remember_fact` proposal as a `Preference` memory fact. If a Preference already
/// exists for the payload's `factKey`, it is *corrected* (append-only revision), never
/// overwritten — Safety Rule #3.
public struct RememberFactHandler: ProposalHandler {
    public let handledType: ProposalType = .rememberFact
    public init() {}

    public func execute(_ proposal: Proposal, grant: ApprovalGrant,
                        context: HandlerContext) async throws -> ExecutionReceipt {
        let payload = try ProposalPayloadCoder.decode(RememberFactPayload.self, from: proposal.payload)
        let store = context.store

        switch try store.resolve(Preference.self, factKey: payload.factKey) {
        case .resolved(let existing):
            try store.correct(existing, reason: "remembered via approved proposal") {
                $0.key = payload.key
                $0.value = payload.value
                $0.confidence = payload.confidence
                $0.source = .user
            }
        default:
            let pref = Preference(source: .user, confidence: payload.confidence,
                                  createdAt: context.clock.now, updatedAt: context.clock.now,
                                  key: payload.key, value: payload.value)
            pref.factKey = payload.factKey
            try store.insert(pref)
        }

        return ExecutionReceipt(proposalAppID: proposal.appID, type: handledType,
                                summary: "Remembered \(payload.key): \(payload.value)")
    }
}
