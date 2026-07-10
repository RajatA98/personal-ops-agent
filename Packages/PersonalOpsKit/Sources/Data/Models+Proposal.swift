import Foundation
import SwiftData
import Core

/// A pending action in the Ops Inbox — the "propose, don't auto-act" unit (Phase 4A owns
/// its state machine and execution handlers; Phase 1 owns its persisted shape).
///
/// A `Proposal` has **two orthogonal lifecycles**, deliberately kept separate:
///   • `status` (`ProposalStatus`: pending → approved/dismissed/snoozed/expired) — the
///     user-facing approve/dismiss flow. Only `approved` ever triggers a handler.
///   • the `MemoryEntity` audit chain (`revision`/`supersededAt`) — when a proposal is
///     re-derived (e.g. a refreshed extraction), the new one supersedes the old while the
///     old row is preserved for audit.
@Model
public final class Proposal: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.reasoning.rawValue
    public var confidence: Double = 0.5
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    public var typeRaw: String = ProposalType.rememberFact.rawValue
    public var statusRaw: String = ProposalStatus.pending.rawValue
    /// Human-readable justification shown in the Ops Inbox.
    public var rationale: String = ""
    /// Opaque typed-action payload (e.g. JSON) interpreted by Phase 4A's per-type handler.
    public var payload: String = ""
    /// Stable app-level ID of the primary object this proposal would affect, if any.
    public var affectedAppID: UUID?

    public var proposalType: ProposalType {
        get { ProposalType(rawValue: typeRaw) ?? .rememberFact }
        set { typeRaw = newValue.rawValue }
    }

    public var status: ProposalStatus {
        get { ProposalStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .reasoning,
        confidence: Double = 0.5,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        type: ProposalType = .rememberFact,
        status: ProposalStatus = .pending,
        rationale: String = "",
        payload: String = "",
        affectedAppID: UUID? = nil
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.typeRaw = type.rawValue
        self.statusRaw = status.rawValue
        self.rationale = rationale
        self.payload = payload
        self.affectedAppID = affectedAppID
    }

    public func makeRevisionCopy() -> Proposal {
        Proposal(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            type: proposalType, status: status, rationale: rationale,
            payload: payload, affectedAppID: affectedAppID
        )
    }
}
