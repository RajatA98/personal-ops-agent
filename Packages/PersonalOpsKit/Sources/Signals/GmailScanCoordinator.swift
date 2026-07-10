import Foundation
import SwiftData
import Core
import Data
import Integrations
import Proposals

/// Summary of one scan pass — surfaced by the "Scan now" affordance and asserted in tests.
public struct GmailScanResult: Equatable, Sendable {
    /// Messages returned by Gmail this pass.
    public let scanned: Int
    /// New pending Proposals actually enqueued.
    public let proposed: Int
    /// Candidates dropped because their source pattern was previously marked wrong (downranking).
    public let suppressedByRejection: Int
    /// Candidates dropped because the thread already has an active Proposal (factKey dedupe).
    public let dedupedByThread: Int

    public init(scanned: Int, proposed: Int, suppressedByRejection: Int, dedupedByThread: Int) {
        self.scanned = scanned
        self.proposed = proposed
        self.suppressedByRejection = suppressedByRejection
        self.dedupedByThread = dedupedByThread
    }
}

/// # GmailScanCoordinator — the Phase 4B pipeline (deterministic, foreground-only)
///
/// Runs one Gmail scan and turns plan-like messages into **pending** Proposals via the Phase 4A
/// engine seam (`enqueueBatch`). It never approves or executes anything — a scan's worst case is
/// a pending item in the Ops Inbox (Safety Rule #1). Background scheduling is deliberately out of
/// scope (PLAN: foreground-only for now); the app triggers this from a "Scan now" affordance.
///
/// ## Three durable de-noising layers (all survive relaunch)
///  1. **Thread-level factKey dedupe** — every Gmail proposal gets the stable factKey
///     `proposal:gmail:<threadID>`; `ProposalEngine.enqueueBatch` skips any thread that already
///     has an active Proposal. Because Proposals are persisted in SwiftData, a re-scan after a
///     relaunch (a *new* engine over the *same* container) still sees the prior proposal — so no
///     second pending Proposal is created for the same thread.
///  2. **Durable scan ledger + cursor** — `SwiftDataGmailMetadataStore` persists every scanned
///     message and the max `receivedDate`, so incremental scans and the "seen" set survive quit.
///  3. **Pattern-level downranking** — before enqueuing, the source pattern (sender domain +
///     subject shape) is checked against `RejectionSignalStore.strength`; a non-zero strength
///     (set when the user marked a similar proposal *wrong*) suppresses the candidate. This
///     generalizes beyond one thread: rejecting one recruiter-noreply "interview confirmed"
///     proposal suppresses future ones from the same sender/subject-shape.
///
/// `@MainActor` because it drives the `ModelContext`-bound engine and memory stores.
@MainActor
public final class GmailScanCoordinator {
    private let context: ModelContext
    private let clock: any Clock
    private let gmail: any GmailAPI
    private let metadataStore: any GmailMetadataStore
    private let extractor: GmailSignalExtractor
    private let engine: ProposalEngine
    /// How long a Gmail-derived proposal lingers before it is swept as expired (never executed).
    private let proposalTTL: TimeInterval

    public init(context: ModelContext,
                gmail: any GmailAPI,
                metadataStore: any GmailMetadataStore,
                clock: any Clock = SystemClock(),
                extractor: GmailSignalExtractor = GmailSignalExtractor(),
                engine: ProposalEngine? = nil,
                proposalTTL: TimeInterval = 14 * 86_400) {
        self.context = context
        self.gmail = gmail
        self.metadataStore = metadataStore
        self.clock = clock
        self.extractor = extractor
        self.engine = engine ?? ProposalEngine(context: context, clock: clock)
        self.proposalTTL = proposalTTL
    }

    /// Run one scan pass.
    ///
    /// - Parameters:
    ///   - query: Gmail search query (default limits to recent mail).
    ///   - since: incremental cursor; defaults to the durable store's `latestReceivedDate`.
    @discardableResult
    public func scanNow(query: String? = "newer_than:14d", since: Date? = nil) async throws -> GmailScanResult {
        let effectiveSince: Date?
        if let since { effectiveSince = since } else { effectiveSince = await metadataStore.latestReceivedDate() }
        let messages = try await gmail.listRecentMessages(query: query, since: effectiveSince)

        // Durable seen-ledger + cursor (layer 2).
        await metadataStore.upsert(messages)

        let now = clock.now
        let rejections = RejectionSignalStore(store: MemoryStore(context: context, clock: clock))

        var candidates: [Proposal] = []
        var suppressed = 0
        for message in messages {
            guard let signal = extractor.extract(from: message) else { continue }

            // Layer 3 — downranking: skip if this source pattern was marked wrong before.
            let pattern = extractor.sourcePattern(for: message)
            let strength = (try? rejections.strength(forSourcePattern: pattern, asOf: now)) ?? 0
            if strength > 0 { suppressed += 1; continue }

            candidates.append(makeProposal(signal, message: message, now: now))
        }

        // Layer 1 — thread-level factKey dedupe (persisted → survives relaunch).
        let before = candidates.count
        let inserted = try engine.enqueueBatch(candidates)
        return GmailScanResult(scanned: messages.count,
                               proposed: inserted.count,
                               suppressedByRejection: suppressed,
                               dedupedByThread: before - inserted.count)
    }

    /// Recompute the stable downrank `sourcePattern` for a thread from the durably-stored
    /// subject/sender. The Ops Inbox calls this when the user taps "mark as wrong" on a
    /// Gmail-derived proposal, then passes the result to `ProposalEngine.markAsWrong(_:sourcePattern:)`
    /// so *future* messages matching the pattern (not just this thread) are suppressed.
    public func sourcePattern(forThreadID threadID: String) async -> String? {
        let records = await allRecords().filter { $0.threadID == threadID }
        guard let record = records.first else { return nil }
        return extractor.sourcePattern(for: record)
    }

    /// The stable factKey a Gmail-derived proposal carries (thread-scoped). Also the string the
    /// Inbox parses back to a threadID for `sourcePattern(forThreadID:)`.
    public static func factKey(forThreadID threadID: String) -> String {
        "proposal:gmail:\(threadID)"
    }

    /// Parse the threadID back out of a Gmail proposal's factKey (inverse of `factKey(forThreadID:)`).
    public static func threadID(fromFactKey factKey: String) -> String? {
        let prefix = "proposal:gmail:"
        guard factKey.hasPrefix(prefix) else { return nil }
        return String(factKey.dropFirst(prefix.count))
    }

    // MARK: - Private

    private func allRecords() async -> [GmailMessageMetadata] {
        await metadataStore.all()
    }

    private func makeProposal(_ signal: GmailSignalExtractor.GmailSignal,
                              message: GmailMessageMetadata,
                              now: Date) -> Proposal {
        let factKey = Self.factKey(forThreadID: message.threadID)
        let expiresAt = now.addingTimeInterval(proposalTTL)

        switch signal {
        case let .event(title, start, end, confidence):
            let payload = CreateAgentCalendarEventPayload(
                title: title, start: start, end: end,
                idempotencyKey: "gmail:\(message.threadID)")
            let proposal = Proposal(
                source: .gmail,
                confidence: confidence,
                createdAt: now, updatedAt: now, expiresAt: expiresAt,
                type: .createAgentCalendarEvent, status: .pending,
                rationale: "Found in an email: \"\(title)\". Add it to your agent calendar?",
                payload: (try? ProposalPayloadCoder.encode(payload)) ?? "")
            proposal.factKey = factKey
            return proposal

        case let .fact(key, value, confidence):
            let payload = RememberFactPayload(
                factKey: "gmail_fact:\(message.threadID)",
                key: key, value: value, confidence: confidence)
            let proposal = Proposal(
                source: .gmail,
                confidence: confidence,
                createdAt: now, updatedAt: now, expiresAt: expiresAt,
                type: .rememberFact, status: .pending,
                rationale: "Found in an email: \"\(value)\". Remember it?",
                payload: (try? ProposalPayloadCoder.encode(payload)) ?? "")
            proposal.factKey = factKey
            return proposal
        }
    }
}
