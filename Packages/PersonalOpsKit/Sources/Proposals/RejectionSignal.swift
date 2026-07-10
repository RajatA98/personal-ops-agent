import Foundation
import Core
import Data

/// # RejectionSignal — the "mark as wrong" record (consumed by Phase 4B)
///
/// When the user marks a Proposal *wrong* (not merely dismisses it), the engine persists a
/// durable rejection signal. Phase 4B reads these to **downrank / suppress** similar future
/// extraction from the same source pattern (its acceptance criterion). This type is the
/// documented shape of that record.
///
/// ## Storage shape (so 4B knows exactly where to read)
/// A rejection is stored as a `Pattern` memory entity — reusing the append-only revision
/// machinery so repeated rejections of the *same* pattern accumulate rather than duplicate:
///   • `factKey` = `"rejection_signal:<proposalType>:<sourcePattern>"` — stable, so a repeat
///     rejection of the same pattern is a *correction* (revision n+1) that bumps `occurrences`.
///   • `name`   = `"rejection_signal"` (a constant tag 4B can filter Patterns by).
///   • `source` = `.user` (the user made this judgment).
///   • `detail` = the JSON-encoded `RejectionSignal` below.
///   • `occurrences` = how many times this exact pattern has been rejected (the downrank weight).
///
/// 4B: to check whether a freshly-extracted candidate should be suppressed, build its
/// `sourcePattern` the same way the extraction tags it, then call
/// `RejectionSignalStore.strength(forSourcePattern:)` (or `.all()`) — a non-zero occurrence
/// count is the downrank signal. `sourcePattern` for a Gmail-derived proposal should be a
/// stable descriptor of the *source* (e.g. sender domain + subject shape), NOT the message ID,
/// so future messages matching the pattern are caught. Phase 4A leaves `sourcePattern` open;
/// 4A's non-Gmail proposals default it to the proposal's `factKey`.
public struct RejectionSignal: Codable, Equatable, Sendable {
    public let proposalType: ProposalType
    public let source: MemorySource
    /// Stable descriptor of the source pattern 4B matches future extractions against.
    public let sourcePattern: String
    /// The specific proposal that was rejected (audit back-reference).
    public let proposalAppID: UUID
    public let rejectedAt: Date

    public init(proposalType: ProposalType, source: MemorySource, sourcePattern: String,
                proposalAppID: UUID, rejectedAt: Date) {
        self.proposalType = proposalType
        self.source = source
        self.sourcePattern = sourcePattern
        self.proposalAppID = proposalAppID
        self.rejectedAt = rejectedAt
    }

    /// The stable `factKey` under which this signal is stored.
    public var factKey: String {
        "rejection_signal:\(proposalType.rawValue):\(sourcePattern)"
    }

    /// Constant `Pattern.name` tag all rejection signals share.
    public static let patternName = "rejection_signal"
}

/// Reads and writes `RejectionSignal`s over a `MemoryStore` (append-only, revisioned). Not
/// `Sendable` — holds a `MemoryStore`; construct on the context's owning actor.
public struct RejectionSignalStore {
    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    /// Record a rejection. First rejection of a pattern inserts a `Pattern` (occurrences 1);
    /// a repeat *corrects* the active one (revision n+1) bumping occurrences — so history is
    /// preserved and the weight grows. Returns the resulting occurrence count.
    @discardableResult
    public func record(_ signal: RejectionSignal) throws -> Int {
        let detail = try ProposalPayloadCoder.encode(signal)

        switch try store.resolve(Pattern.self, factKey: signal.factKey) {
        case .resolved(let existing):
            let bumped = existing.occurrences + 1
            try store.correct(existing, reason: "rejection reinforced", asOf: signal.rejectedAt) {
                $0.occurrences = bumped
                $0.detail = detail
                $0.source = .user
            }
            return bumped
        default:
            let pattern = Pattern(source: .user, confidence: 1.0,
                                  createdAt: signal.rejectedAt, updatedAt: signal.rejectedAt,
                                  name: RejectionSignal.patternName, detail: detail, occurrences: 1)
            pattern.factKey = signal.factKey
            try store.insert(pattern)
            return 1
        }
    }

    /// All currently-active rejection signals with their occurrence weight.
    public func all(asOf: Date? = nil) throws -> [(signal: RejectionSignal, occurrences: Int)] {
        let patterns = try store.all(Pattern.self).filter {
            $0.name == RejectionSignal.patternName && $0.isActive(asOf: asOf ?? $0.updatedAt)
        }
        return patterns.compactMap { p in
            guard let signal = try? ProposalPayloadCoder.decode(RejectionSignal.self, from: p.detail)
            else { return nil }
            return (signal, p.occurrences)
        }
    }

    /// Total downrank strength for a given source pattern (0 = never rejected). Phase 4B's
    /// suppression check.
    public func strength(forSourcePattern pattern: String, asOf: Date? = nil) throws -> Int {
        try all(asOf: asOf)
            .filter { $0.signal.sourcePattern == pattern }
            .reduce(0) { $0 + $1.occurrences }
    }
}
