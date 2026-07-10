import Foundation
import Core
import Data

/// # ShortcutIntakeService — the iMessage / Shortcuts intake seam (Phase 4C)
///
/// The single entry point a Shortcuts "When I get a message" personal automation reaches
/// (through the app's App Intent). It takes an **untrusted** chunk of forwarded text and, at
/// most, produces a *pending* Proposal in the Ops Inbox — it can never write to memory or a
/// calendar directly (that stays gated behind user approval in `ProposalEngine`, Safety Rule #1).
///
/// Contract (PRD iMessage + Integration Failure Modes):
///   • Empty / whitespace-only / malformed payload → **dropped, no Proposal** (logged, not
///     guessed into memory).
///   • A payload whose `receivedAt` is older than `maxAge` (a delayed automation firing late) →
///     **dropped as stale**, no Proposal.
///   • Valid text → deterministically classified (`PlanTextExtractor`) into a `pending`
///     Proposal tagged with `MemorySource.iMessage` (explicit untrusted/best-effort provenance),
///     low confidence. A schedulable date/time → `create_agent_calendar_event`; otherwise a
///     `remember_fact` note to review. Never a silent write.
///
/// The raw text is Local-only (PRD Data Boundaries): it is placed only into the local Proposal
/// queue and is never logged (`log` receives metadata only).
@MainActor
public struct ShortcutIntakeService {
    private let engine: ProposalEngine
    private let extractor: PlanTextExtractor
    private let maxAge: TimeInterval
    private let log: ((String) -> Void)?

    /// - Parameters:
    ///   - engine: where a valid payload is enqueued (the only thing this service can do).
    ///   - maxAge: how late a `receivedAt` can be before the payload is dropped as stale
    ///     (default 24h — a personal automation that fires a day late is best-effort noise).
    ///   - log: metadata-only sink (outcome + reason + length). **Never** receives the text.
    public init(engine: ProposalEngine,
                extractor: PlanTextExtractor = PlanTextExtractor(),
                maxAge: TimeInterval = 24 * 60 * 60,
                log: ((String) -> Void)? = nil) {
        self.engine = engine
        self.extractor = extractor
        self.maxAge = maxAge
        self.log = log
    }

    /// Why a payload produced no Proposal.
    public enum DropReason: String, Sendable, Equatable {
        case empty        // nil / whitespace-only text
        case stale        // receivedAt older than maxAge (delayed automation)
        case future       // receivedAt implausibly in the future (malformed)
    }

    /// The result of an intake attempt.
    public enum Outcome: Sendable, Equatable {
        case enqueued(proposalAppID: UUID, type: ProposalType)
        case dropped(DropReason)

        public var isDropped: Bool { if case .dropped = self { return true }; return false }
    }

    /// Ingest one forwarded message. `now` is the current instant; `receivedAt` (optional) is
    /// when the Shortcut says the message arrived — used only for the staleness check.
    @discardableResult
    public func ingest(text: String?, receivedAt: Date? = nil, now: Date) throws -> Outcome {
        // 1. Validate presence.
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            log?("intake dropped: empty payload")
            return .dropped(.empty)
        }

        // 2. Validate freshness (a delayed / malformed timestamp is dropped, not guessed).
        if let received = receivedAt {
            if received > now.addingTimeInterval(5 * 60) {
                log?("intake dropped: future timestamp")
                return .dropped(.future)
            }
            if now.timeIntervalSince(received) > maxAge {
                log?("intake dropped: stale (\(Int(now.timeIntervalSince(received)))s old)")
                return .dropped(.stale)
            }
        }

        // 3. Classify deterministically and enqueue a *pending* Proposal.
        let referenceDate = receivedAt ?? now
        guard let classification = extractor.classify(raw, referenceDate: referenceDate) else {
            log?("intake dropped: no usable content")
            return .dropped(.empty)
        }

        let key = Self.stableKey(raw)
        let proposal: Proposal
        switch classification {
        case .event(let candidate):
            proposal = eventProposal(candidate, rawLength: raw.count, now: now, key: key)
        case .note(let note):
            proposal = noteProposal(note, now: now, key: key)
        }

        // Re-forwarding the same message reuses the same stable `factKey`; collapse it onto the
        // existing pending item rather than stacking a duplicate in the Inbox.
        if let existing = try engine.pendingProposals()
            .first(where: { $0.factKey == proposal.factKey }) {
            log?("intake deduped onto existing pending proposal (\(raw.count) chars)")
            return .enqueued(proposalAppID: existing.appID, type: existing.proposalType)
        }

        try engine.enqueue(proposal)
        log?("intake enqueued: \(proposal.proposalType.rawValue) (\(raw.count) chars)")
        return .enqueued(proposalAppID: proposal.appID, type: proposal.proposalType)
    }

    // MARK: - Proposal construction (untrusted provenance)

    private func eventProposal(_ candidate: PlanTextExtractor.EventCandidate,
                               rawLength: Int, now: Date, key: String) -> Proposal {
        let payload = CreateAgentCalendarEventPayload(
            title: candidate.title,
            start: candidate.start,
            end: candidate.end,
            idempotencyKey: "imessage:\(key)")
        let proposal = Proposal(
            source: .iMessage,
            confidence: 0.35,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(14 * 86_400),
            type: .createAgentCalendarEvent,
            status: .pending,
            rationale: "From a forwarded message (untrusted): \"\(candidate.title)\". Review before it goes on your agent calendar.",
            payload: (try? ProposalPayloadCoder.encode(payload)) ?? "",
            affectedAppID: nil)
        proposal.factKey = "proposal:imessage:event:\(key)"
        return proposal
    }

    private func noteProposal(_ note: String, now: Date, key: String) -> Proposal {
        let payload = RememberFactPayload(
            factKey: "imessage:note:\(key)",
            key: "captured_message",
            value: note,
            confidence: 0.35)
        let proposal = Proposal(
            source: .iMessage,
            confidence: 0.35,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(14 * 86_400),
            type: .rememberFact,
            status: .pending,
            rationale: "From a forwarded message (untrusted). Remember this note? \"\(note.prefix(120))\"",
            payload: (try? ProposalPayloadCoder.encode(payload)) ?? "",
            affectedAppID: nil)
        proposal.factKey = "proposal:imessage:note:\(key)"
        return proposal
    }

    /// A stable, deterministic key for a piece of text (FNV-1a) — so re-forwarding the same
    /// message reuses the same `factKey` and `enqueueBatch`/dedupe collapses it rather than
    /// stacking duplicate proposals. Not security-sensitive; just needs to be reproducible
    /// (Swift's built-in `Hasher` is per-process randomized, so it is unsuitable here).
    static func stableKey(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
