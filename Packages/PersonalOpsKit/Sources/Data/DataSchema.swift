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

/// # V2 — adds `GmailMessageRecord` (Phase 4B)
///
/// The only delta from V1 is the **addition** of the `GmailMessageRecord` model (the durable
/// Gmail scan ledger that lets thread dedupe survive relaunch). Because the change is purely
/// additive — a brand-new model, no field changed on any existing model — the V1→V2 migration
/// is `.lightweight` (SwiftData infers it; no data transform needed), which is exactly the
/// CloudKit-safe kind of change (additive, optional/defaulted, no unique constraints).
public enum DataSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        DataSchemaV1.models + [GmailMessageRecord.self]
    }
}

/// # V3 — adds `HealthSummaryRecord` (Phase 7B)
///
/// The only delta from V2 is the **addition** of `HealthSummaryRecord` (the syncable, persisted
/// per-day health summary that lets the macOS app consume HealthKit-derived pacing as *synced
/// data* rather than reading HealthKit natively). Like V1→V2, the change is purely additive — a
/// brand-new model, no field changed on any existing model — so the V2→V3 migration is
/// `.lightweight` (SwiftData infers it; no data transform), the CloudKit-safe kind of change
/// (additive, optional/defaulted, no unique constraints). This is exactly the additive
/// `DataSchemaV3` + `.lightweight` stage that Phase 7A's handoff anticipated for the synced
/// HealthSummary path.
public enum DataSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        DataSchemaV2.models + [HealthSummaryRecord.self]
    }
}

/// Ordered list of schema versions and the migration stages between them. V1 is the baseline;
/// V2 adds `GmailMessageRecord`, V3 adds `HealthSummaryRecord` — each via a single lightweight stage.
public enum MemoryMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DataSchemaV1.self, DataSchemaV2.self, DataSchemaV3.self]
    }

    public static var stages: [MigrationStage] {
        [
            // Additive-only (new model): SwiftData handles each as a lightweight migration.
            .lightweight(fromVersion: DataSchemaV1.self, toVersion: DataSchemaV2.self),
            .lightweight(fromVersion: DataSchemaV2.self, toVersion: DataSchemaV3.self)
        ]
    }
}

/// # CloudKit sync state (Phase 7A)
///
/// The observable, user-visible state of iPhone↔Mac sync. Kept deliberately small because
/// SwiftData exposes almost nothing about the underlying `NSPersistentCloudKitContainer`
/// mirroring status — there is no public "last synced at" or per-record progress. So the
/// honest surface is: is CloudKit *configured on this container*, and if we asked for it,
/// did the container actually come up with it (vs. fall back to local-only)?
///
///   • `.off`        — sync not requested (the default; local-only, single-device).
///   • `.active`     — the container was built with the CloudKit private database attached.
///                     (That the mirroring is *working* still needs an iCloud-entitled device
///                     build with two signed-in devices — see `docs/CLOUDKIT_SETUP.md`.)
///   • `.unavailable`— sync was requested but the CloudKit container could not be built
///                     (no iCloud entitlement/account — the simulator/free-tier case); we
///                     degraded to a fully-working local-only store and say so, never crash.
public enum CloudKitSyncState: Equatable, Sendable {
    case off
    case active
    case unavailable(reason: String)

    /// Short label for the Settings sync row.
    public var label: String {
        switch self {
        case .off: return "Off"
        case .active: return "On"
        case .unavailable: return "Unavailable"
        }
    }
}

/// A resolved container plus the sync state it actually came up in. The app composition root
/// uses `DataStore.resolve(...)` (not the raw `makeContainer`) so that requesting CloudKit on
/// a device without iCloud degrades gracefully to local-only with a visible state.
public struct ResolvedContainer {
    public let container: ModelContainer
    public let syncState: CloudKitSyncState
    public init(container: ModelContainer, syncState: CloudKitSyncState) {
        self.container = container
        self.syncState = syncState
    }
}

/// Factory for the app's `ModelContainer`, built from the versioned schema and migration
/// plan. One place owns container construction so the app, tests, and (Phase 7A) CloudKit
/// all go through the same configuration.
public enum DataStore {

    /// The CloudKit **private database** container identifier. Convention: `iCloud.` + the app's
    /// bundle ID. This is the container SwiftData mirrors into when `cloudKit: true`; it must also
    /// appear in the app's `com.apple.developer.icloud-container-identifiers` entitlement
    /// (see `App/App.entitlements`) and be created in the CloudKit dashboard on a **paid** Apple
    /// Developer account (a free personal team cannot provision a CloudKit container — see
    /// `docs/CLOUDKIT_SETUP.md` for the free-vs-paid truth).
    public static let cloudKitContainerIdentifier = "iCloud.com.rajatarora.PersonalOpsAgent"

    /// The current schema, built from the versioned schema (not an ad-hoc model list) so
    /// it always matches the migration plan. Points at the newest version (V3).
    public static var schema: Schema {
        Schema(versionedSchema: DataSchemaV3.self)
    }

    /// Build a container. **The single construction point** — the app, tests, previews, and the
    /// CloudKit path all route through here so configuration never diverges.
    ///
    /// - Parameters:
    ///   - inMemory: `true` for tests/previews (nothing written to disk). Ignored when `url` is set.
    ///   - cloudKit: whether to attach the CloudKit private database (`.private(containerID)`).
    ///     When `true`, SwiftData mirrors the store into the user's private iCloud database and
    ///     validates the schema against CloudKit's constraints at construction time — which is
    ///     why an unentitled build **throws here** (caught + degraded by `resolve(...)`).
    ///   - url: an explicit on-disk store location. Used by the migration/graceful-degradation
    ///     tests so they don't touch the app's default store. `nil` = SwiftData's default location.
    public static func makeContainer(
        inMemory: Bool = false,
        cloudKit: Bool = false,
        url: URL? = nil
    ) throws -> ModelContainer {
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase =
            cloudKit ? .private(cloudKitContainerIdentifier) : .none
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: cloudKitDatabase)
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: cloudKitDatabase
            )
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: MemoryMigrationPlan.self,
            configurations: configuration
        )
    }

    /// Resolve the app's container with **graceful CloudKit degradation** (Phase 7A).
    ///
    /// When `preferCloudKit` is true we try to build the CloudKit-attached container; if that
    /// throws — the simulator/free-tier case, where there is no iCloud entitlement or account —
    /// we fall back to a fully-working **local-only** container and report `.unavailable(reason:)`
    /// rather than crashing. Flipping the CloudKit flag therefore never breaks the no-iCloud case:
    /// the app still launches and works single-device, and the Settings sync row shows *why* sync
    /// isn't active. When `preferCloudKit` is false the container is plain local-only (`.off`).
    ///
    /// This is the method the app composition root calls; `makeContainer` stays the low-level
    /// single construction point it delegates to.
    public static func resolve(
        preferCloudKit: Bool,
        inMemory: Bool = false,
        url: URL? = nil
    ) throws -> ResolvedContainer {
        try resolve(preferCloudKit: preferCloudKit, inMemory: inMemory, url: url,
                    cloudKitBuild: { try makeContainer(inMemory: inMemory, cloudKit: true, url: url) })
    }

    /// Internal resolution seam with an injectable CloudKit build step, so the graceful-degradation
    /// path can be exercised **deterministically** in `swift test` regardless of whether the host
    /// happens to have iCloud (a dev Mac may actually build the CloudKit container, whereas a bare
    /// simulator/CI won't — we must not depend on which). Production calls the public overload,
    /// which supplies the real CloudKit build.
    static func resolve(
        preferCloudKit: Bool,
        inMemory: Bool,
        url: URL?,
        cloudKitBuild: () throws -> ModelContainer
    ) throws -> ResolvedContainer {
        guard preferCloudKit else {
            return ResolvedContainer(
                container: try makeContainer(inMemory: inMemory, cloudKit: false, url: url),
                syncState: .off)
        }
        do {
            return ResolvedContainer(container: try cloudKitBuild(), syncState: .active)
        } catch {
            // CloudKit couldn't be attached (no entitlement / no iCloud account / unavailable).
            // Degrade to local-only — a working store beats a crash — and surface the reason.
            let container = try makeContainer(inMemory: inMemory, cloudKit: false, url: url)
            return ResolvedContainer(
                container: container,
                syncState: .unavailable(reason: cloudKitFailureReason(error)))
        }
    }

    /// A short, user-readable reason CloudKit couldn't be attached, distilled from the underlying
    /// error. Kept generic because the underlying `NSError`s are noisy and version-specific.
    static func cloudKitFailureReason(_ error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("entitlement") {
            return "This build isn't set up for iCloud (missing CloudKit entitlement). Running local-only."
        }
        if text.contains("account") || text.contains("not signed in") || text.contains("no icloud") {
            return "No iCloud account is available on this device. Running local-only."
        }
        return "iCloud sync is unavailable right now. Running local-only."
    }
}
