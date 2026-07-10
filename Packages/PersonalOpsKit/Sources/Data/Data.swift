import Foundation
import Core

/// # Data module (persistence boundary)
///
/// Phase 1 implemented this: SwiftData models for the typed entities (`DailyLog`,
/// `Commitment`, `Goal`, `GoalTask`, `GoalProgress`, `Decision`, `Preference`,
/// `OpenLoop`, `Pattern`, `Proposal`), the append-only versioned memory system
/// (`MemoryEntity` / `MemoryStore`), and a CloudKit-compatible schema
/// (`DataSchemaV1` + `MemoryMigrationPlan`, built by `DataStore`).
///
/// The stable app-level identifier convention (separate from SwiftData object identity,
/// required for CloudKit) is defined here; every model conforms to `AppEntity`.
public protocol AppEntity {
    /// Stable, app-assigned identity — distinct from SwiftData's `PersistentIdentifier`
    /// and stable across CloudKit sync. Every model carries one, minted at creation and
    /// never reused (a correction mints a fresh `appID` for the new revision).
    var appID: UUID { get }
}

public enum DataModule {
    /// Marketing marker for the current on-disk schema. The authoritative version lives on
    /// `DataSchemaV1.versionIdentifier`; this mirrors its major component for quick checks
    /// and is bumped in lockstep whenever a new `DataSchemaVN` is introduced.
    /// Phase 0 shipped `0` (no models). Phase 1 ships schema V1. Phase 4B ships V2 (adds
    /// `GmailMessageRecord`, the durable Gmail scan ledger). Phase 7B ships V3 (adds
    /// `HealthSummaryRecord`, the syncable health summary for the macOS pacing path) — both
    /// purely additive changes.
    public static let schemaVersion = 3
}
