import Foundation
import Core

/// # Memory lifecycle contract (append-only, versioned, correctable)
///
/// Every fact-bearing model in the store is a `MemoryEntity`. The memory system is
/// **append-only at the audit layer**: a correction never overwrites a row — it inserts a
/// *new revision* and marks the prior row `superseded` (preserving its value, source,
/// timestamp, and the correction reason). Queries resolve to the single active,
/// non-expired revision by default; history queries return everything; and when two
/// active revisions exist for the same fact with neither superseding the other, the store
/// surfaces an explicit *conflict* rather than picking an arbitrary winner.
///
/// ## Identity model (three distinct IDs — this is deliberate)
/// - `appID`: stable app-level identity of *this specific revision*, distinct from
///   SwiftData's `PersistentIdentifier` and stable across CloudKit sync (the `AppEntity`
///   convention). Every revision has its own `appID`.
/// - `factKey`: the semantic identity of *what fact this is about* (e.g.
///   `"preference:morning_workout_window"`). All revisions of one fact — and any
///   conflicting independent claims about it — share a `factKey`. This is what "the same
///   fact" means for correction and conflict detection.
/// - `supersededByAppID`: back-pointer from a superseded revision to the `appID` of the
///   revision that replaced it, so the audit chain is walkable.
public protocol MemoryEntity: AppEntity, AnyObject {
    /// Semantic identity of the fact this revision describes. Shared across all revisions
    /// of the fact and across conflicting independent claims about it.
    var factKey: String { get set }

    /// Monotonic revision number within a `factKey` chain. First revision is `1`.
    var revision: Int { get set }

    /// Raw provenance string. Access the typed value via ``MemoryEntity/source``.
    var sourceRaw: String { get set }

    /// 0.0–1.0 confidence in this revision's value.
    var confidence: Double { get set }

    /// When this revision was created.
    var createdAt: Date { get set }

    /// When this revision was last touched (created, or marked superseded).
    var updatedAt: Date { get set }

    /// Optional expiry. A revision past its `expiresAt` is excluded from default queries
    /// but retained in history.
    var expiresAt: Date? { get set }

    /// Set when this revision has been replaced by a correction. Non-nil ⇒ superseded.
    var supersededAt: Date? { get set }

    /// `appID` of the revision that superseded this one (nil while active).
    var supersededByAppID: UUID? { get set }

    /// Human-readable reason a correction was made (carried by the *new* revision).
    var correctionReason: String? { get set }

    /// Produce a brand-new, un-inserted duplicate of this revision: identical value fields,
    /// `factKey`, source, confidence and expiry, but a fresh `appID` and a clean
    /// (non-superseded) audit state. The store bumps the revision number, stamps
    /// timestamps, and records the correction reason. Each concrete model implements this
    /// because only it knows its own value fields.
    func makeRevisionCopy() -> Self
}

public extension MemoryEntity {
    /// Typed provenance accessor over ``sourceRaw``.
    var source: MemorySource {
        get { MemorySource(rawValue: sourceRaw) ?? .system }
        set { sourceRaw = newValue.rawValue }
    }

    /// Whether this revision still supersedes nothing and is not itself superseded.
    var isSuperseded: Bool { supersededAt != nil }

    /// Whether this revision has passed its expiry as of `asOf`.
    func isExpired(asOf: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= asOf
    }

    /// Active = not superseded and not expired. This is what a default query returns.
    func isActive(asOf: Date) -> Bool {
        !isSuperseded && !isExpired(asOf: asOf)
    }
}

/// The result of resolving a `factKey` to its current truth.
///
/// The `.conflict` case is the whole point: two active revisions for the same fact, with
/// neither registered as a correction of the other, are surfaced explicitly. The system
/// never silently picks a winner — that would be a fabricated certainty.
///
/// Not `Sendable`: `Entity` is a SwiftData `@Model` (a reference type bound to its
/// `ModelContext`'s actor), so the resolution is used on that same actor, never shared.
public enum MemoryResolution<Entity> where Entity: AnyObject {
    /// No active revision exists for the fact (none recorded, or all expired/superseded).
    case none
    /// Exactly one active revision — the unambiguous current value.
    case resolved(Entity)
    /// Two or more active revisions with no supersession chain between them. Caller must
    /// disambiguate (surface an Ops Inbox item, ask the user, etc.).
    case conflict([Entity])

    /// The single resolved value, or nil for `.none` / `.conflict`.
    public var value: Entity? {
        if case let .resolved(entity) = self { return entity }
        return nil
    }

    /// True only for `.conflict`.
    public var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }
}
