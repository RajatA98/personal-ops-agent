import Foundation
import SwiftData
import Core
import Data
import Integrations
@testable import Proposals

/// Shared fixtures for the Phase 4A proposal tests. In-memory container, fixed anchor date.
@MainActor
enum PX {
    static let now = Date(timeIntervalSince1970: 10 * 86_400)
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    static func context() throws -> ModelContext {
        ModelContext(try DataStore.makeContainer(inMemory: true))
    }

    /// Build a pending proposal of a given type with an encodable payload.
    static func pending<P: Encodable>(_ type: ProposalType,
                                      payload: P,
                                      factKey: String = "proposal:test:\(UUID().uuidString)",
                                      expiresAt: Date? = nil,
                                      now: Date = PX.now) -> Proposal {
        let p = Proposal(
            source: .reasoning, createdAt: now, updatedAt: now, expiresAt: expiresAt,
            type: type, status: .pending, rationale: "test",
            payload: (try? ProposalPayloadCoder.encode(payload)) ?? "")
        p.factKey = factKey
        return p
    }
}

/// A spy handler that records how many times it executed and for which proposal. Used to prove
/// that approving a proposal invokes ONLY its own handler — every other type's spy stays at 0.
@MainActor
final class SpyHandler: ProposalHandler {
    let handledType: ProposalType
    private(set) var executeCount = 0
    private(set) var lastProposalAppID: UUID?
    var onExecute: (() -> Void)?

    init(_ type: ProposalType) { self.handledType = type }

    func execute(_ proposal: Proposal, grant: ApprovalGrant,
                 context: HandlerContext) async throws -> ExecutionReceipt {
        executeCount += 1
        lastProposalAppID = proposal.appID
        onExecute?()
        return ExecutionReceipt(proposalAppID: proposal.appID, type: handledType, summary: "spy ran")
    }
}
