import Foundation
import Core

/// # Data module (persistence boundary)
///
/// Phase 1 fills this in: SwiftData models for the typed entities (`DailyLog`,
/// `Commitment`, `Goal`, `GoalTask`, `GoalProgress`, `Decision`, `Preference`,
/// `OpenLoop`, `Pattern`, `Proposal`), the append-only versioned memory system, and a
/// CloudKit-compatible schema (stable app-level IDs, optional/default values, migration
/// strategy). **No entity models exist in Phase 0** — this is the module home only.
///
/// The stable app-level identifier convention (separate from SwiftData object identity,
/// required for CloudKit) is seeded here so Phase 1 has a fixed type to build on.
public protocol AppEntity {
    /// Stable, app-assigned identity — distinct from SwiftData's `PersistentIdentifier`
    /// and stable across CloudKit sync. Phase 1 conforms its models to this.
    var appID: UUID { get }
}

public enum DataModule {
    /// Schema version marker; Phase 1 owns the real migration/versioning strategy.
    public static let schemaVersion = 0
}
