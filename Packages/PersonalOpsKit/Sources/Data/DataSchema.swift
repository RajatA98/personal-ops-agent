import Foundation
import SwiftData

/// # Schema versioning & migration strategy
///
/// SwiftData's `VersionedSchema` + `SchemaMigrationPlan` are used from day one so the
/// upgrade path is explicit rather than implicit. Phase 1 ships **V1** as the baseline
/// (no prior version to migrate from), but the machinery is in place so a future change
/// is a bounded, testable edit rather than a rewrite:
///
/// 1. Introduce `DataSchemaV2: VersionedSchema` listing the changed model set.
/// 2. Add a `MigrationStage` to `MemoryMigrationPlan.stages` — `.lightweight` for
///    additive/renamed-with-default changes, `.custom` when data must be transformed
///    (e.g. back-filling `factKey`s or splitting a field).
/// 3. Bump `DataModule.schemaVersion` in lockstep with the new major version.
///
/// Because this is CloudKit-bound (sync activates in Phase 7A), migrations must stay within
/// CloudKit's constraints — additive, optional/defaulted, no unique constraints, no
/// removal of a field still present in a peer's synced records until all peers migrate.
public enum DataSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            DailyLog.self,
            Commitment.self,
            Goal.self,
            GoalTask.self,
            GoalProgress.self,
            Decision.self,
            Preference.self,
            OpenLoop.self,
            Pattern.self,
            Proposal.self
        ]
    }
}

/// Ordered list of schema versions and the migration stages between them. V1 is the
/// baseline, so `stages` is empty; a V2 adds one stage here.
public enum MemoryMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DataSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        [] // No migrations yet — V1 is the initial schema.
    }
}

/// Factory for the app's `ModelContainer`, built from the versioned schema and migration
/// plan. One place owns container construction so the app, tests, and (Phase 7A) CloudKit
/// all go through the same configuration.
public enum DataStore {

    /// The current schema, built from the versioned schema (not an ad-hoc model list) so
    /// it always matches the migration plan.
    public static var schema: Schema {
        Schema(versionedSchema: DataSchemaV1.self)
    }

    /// Build a container.
    ///
    /// - Parameters:
    ///   - inMemory: `true` for tests/previews (nothing written to disk).
    ///   - cloudKit: whether to activate CloudKit sync. **Phase 1 always passes `false`** —
    ///     the schema is CloudKit-*compatible* now, but sync itself is switched on and
    ///     hardened in Phase 7A (it needs an iCloud-entitled build to validate on-device).
    public static func makeContainer(
        inMemory: Bool = false,
        cloudKit: Bool = false
    ) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: cloudKit ? .automatic : .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: MemoryMigrationPlan.self,
            configurations: configuration
        )
    }
}
