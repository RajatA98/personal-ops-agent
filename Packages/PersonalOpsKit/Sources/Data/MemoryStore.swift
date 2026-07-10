import Foundation
import SwiftData
import Core

/// # MemoryStore — the append-only, versioned query/correction engine
///
/// Wraps a `ModelContext` and a `Clock` and enforces the memory lifecycle over any
/// `MemoryEntity` model:
///   • **Correct, don't overwrite** — `correct(_:)` inserts a new revision and marks the
///     prior one superseded (never mutates its value, never deletes it).
///   • **Default = active** — `resolve(_:factKey:)` returns the single active, non-expired
///     revision, or an explicit `.conflict` when two independent active revisions exist.
///   • **History = everything** — `history(_:factKey:)` returns all revisions, including
///     superseded and expired ones.
///
/// ## Why post-fetch filtering (not `#Predicate`)
/// A generic `#Predicate` over a protocol requirement (`MemoryEntity.factKey`) does not
/// compile. We fetch by concrete type and filter/resolve in Swift, which also lets us
/// inject the `Clock` for expiry decisions (predicates can't call an injected clock).
/// Data volume is single-user scale, so this is not a performance concern in Phase 1;
/// Phase 7A can add per-concrete-type indexed predicates if a corpus ever grows large.
///
/// Not `Sendable`: a `ModelContext` must be used on its owning actor. Construct a
/// `MemoryStore` where the context lives (the app's main context, or a test's context).
public struct MemoryStore {
    private let context: ModelContext
    private let clock: any Clock

    public init(context: ModelContext, clock: any Clock = SystemClock()) {
        self.context = context
        self.clock = clock
    }

    // MARK: Writes

    /// Insert a brand-new memory fact (revision 1). Stamps `createdAt`/`updatedAt` from the
    /// clock if the caller left them at their construction defaults is *not* assumed — the
    /// caller owns the entity's timestamps; this simply inserts and saves.
    public func insert<T: PersistentModel & MemoryEntity>(_ entity: T) throws {
        context.insert(entity)
        try context.save()
    }

    /// Record a correction. Creates revision *n+1* (a fresh `appID`, clean audit state),
    /// lets the caller mutate its value fields via `mutate`, and marks revision *n*
    /// superseded — preserving *n*'s value, source, timestamp, and now a back-pointer to
    /// the revision that replaced it. Returns the new active revision.
    ///
    /// - Parameters:
    ///   - old: the currently-active revision being corrected.
    ///   - reason: why the correction was made (carried on the new revision).
    ///   - asOf: timestamp for the correction; defaults to the injected clock.
    ///   - mutate: closure that sets the new revision's corrected value fields.
    @discardableResult
    public func correct<T: PersistentModel & MemoryEntity>(
        _ old: T,
        reason: String,
        asOf: Date? = nil,
        mutate: (T) -> Void
    ) throws -> T {
        let now = asOf ?? clock.now

        let new = old.makeRevisionCopy()
        new.revision = old.revision + 1
        new.createdAt = now
        new.updatedAt = now
        new.supersededAt = nil
        new.supersededByAppID = nil
        new.correctionReason = reason
        mutate(new)

        old.supersededAt = now
        old.supersededByAppID = new.appID
        old.updatedAt = now

        context.insert(new)
        try context.save()
        return new
    }

    /// Mark a revision expired as of a given date, without creating a new revision. The
    /// revision remains in history; it simply drops out of active/default queries.
    public func expire<T: PersistentModel & MemoryEntity>(_ entity: T, asOf: Date? = nil) throws {
        let now = asOf ?? clock.now
        entity.expiresAt = now
        entity.updatedAt = now
        try context.save()
    }

    // MARK: Reads

    /// Every revision of every `factKey` for a type (unfiltered), newest `revision` first.
    public func all<T: PersistentModel & MemoryEntity>(_ type: T.Type) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// Full audit history for one fact — all revisions, including superseded and expired,
    /// ordered by ascending `revision`.
    public func history<T: PersistentModel & MemoryEntity>(
        _ type: T.Type,
        factKey: String
    ) throws -> [T] {
        try all(type)
            .filter { $0.factKey == factKey }
            .sorted { $0.revision < $1.revision }
    }

    /// The active (non-superseded, non-expired) revisions for one fact as of `asOf`.
    /// Normally 0 or 1; more than one means a conflict.
    public func activeRevisions<T: PersistentModel & MemoryEntity>(
        _ type: T.Type,
        factKey: String,
        asOf: Date? = nil
    ) throws -> [T] {
        let now = asOf ?? clock.now
        return try history(type, factKey: factKey).filter { $0.isActive(asOf: now) }
    }

    /// Resolve one fact to its current truth: `.none`, `.resolved(one)`, or `.conflict(many)`.
    /// This is the default query — it never picks an arbitrary winner among conflicts.
    public func resolve<T: PersistentModel & MemoryEntity>(
        _ type: T.Type,
        factKey: String,
        asOf: Date? = nil
    ) throws -> MemoryResolution<T> {
        let active = try activeRevisions(type, factKey: factKey, asOf: asOf)
        switch active.count {
        case 0: return .none
        case 1: return .resolved(active[0])
        default: return .conflict(active)
        }
    }

    /// All currently-active revisions of a type, grouped by `factKey`. Convenience for the
    /// memory browser UI (shows one active row per fact, conflicts included).
    public func activeByFact<T: PersistentModel & MemoryEntity>(
        _ type: T.Type,
        asOf: Date? = nil
    ) throws -> [String: [T]] {
        let now = asOf ?? clock.now
        let active = try all(type).filter { $0.isActive(asOf: now) }
        return Dictionary(grouping: active, by: { $0.factKey })
    }
}
