import XCTest
import SwiftData
import Core
@testable import Data

/// # Phase 7A — CloudKit enablement, schema tripwire, and graceful degradation
///
/// These are the host-side checks that can be proven without an iCloud-entitled device build.
/// Real cross-device mirroring still needs the device matrix in `docs/CLOUDKIT_SETUP.md`.
final class CloudKitSyncTests: XCTestCase {

    // MARK: - Schema regression tripwire

    /// The live shipped schema passes every reflectable CloudKit constraint. If a future phase
    /// adds a unique attribute, a non-optional relationship, or a relationship without an inverse,
    /// this fails in plain `swift test` — long before it would surface on a synced device.
    func test_currentSchema_hasNoCloudKitViolations() {
        let violations = CloudKitSchemaValidator.violations(in: DataStore.schema)
        XCTAssertEqual(violations, [], "CloudKit-incompatible field introduced:\n" +
                       violations.map { "  • \($0)" }.joined(separator: "\n"))
    }

    /// Proves the tripwire actually fires — a model with a uniqueness constraint is reported.
    /// (This is the "provably fails on a violation" demonstration the acceptance criteria ask for,
    /// using a test-local intentionally-bad model so the real schema stays clean.)
    func test_validator_flagsUniquenessConstraint() {
        let badSchema = Schema([BadUniqueModel.self])
        let violations = CloudKitSchemaValidator.violations(in: badSchema)
        XCTAssertTrue(violations.contains { $0.kind == .uniquenessConstraint },
                      "validator must catch a uniqueness constraint; got \(violations)")
    }

    /// Proves the tripwire fires on a non-optional relationship too.
    func test_validator_flagsNonOptionalRelationship() {
        let badSchema = Schema([BadParent.self, BadChild.self])
        let violations = CloudKitSchemaValidator.violations(in: badSchema)
        XCTAssertTrue(violations.contains { $0.kind == .nonOptionalRelationship },
                      "validator must catch a non-optional relationship; got \(violations)")
    }

    // MARK: - Graceful degradation when iCloud is unavailable

    /// **Deterministic** graceful-degradation: when the CloudKit build step fails (the simulator /
    /// free-tier case — no iCloud entitlement or account), `resolve` must NOT crash. It must fall
    /// back to a fully-working local-only store and report a visible `.unavailable(reason:)`. We
    /// inject a throwing CloudKit build so this exercises the real fallback path on every host,
    /// regardless of whether the machine happens to have iCloud.
    func test_cloudKitBuildFails_degradesToLocalOnly_withVisibleReason_noCrash() throws {
        let url = Self.tempStoreURL()
        defer { Self.removeStore(at: url) }

        struct SimulatedCloudKitError: Error { let localizedDescription = "missing CloudKit entitlement" }
        let resolved = try DataStore.resolve(
            preferCloudKit: true, inMemory: false, url: url,
            cloudKitBuild: { throw SimulatedCloudKitError() })

        // Visible state, not a crash.
        guard case let .unavailable(reason) = resolved.syncState else {
            return XCTFail("a failed CloudKit build must degrade to .unavailable, got \(resolved.syncState)")
        }
        XCTAssertFalse(reason.isEmpty, "an unavailable state must explain why")

        // The fallback container is fully usable — local-only, no data loss.
        let context = ModelContext(resolved.container)
        context.insert(Preference(factKey: "pref:x", key: "k", value: "v"))
        XCTAssertNoThrow(try context.save())
        XCTAssertEqual(try context.fetch(FetchDescriptor<Preference>()).count, 1)
    }

    /// The real CloudKit build path (no injection) must never crash either — on an entitled host it
    /// comes up `.active`, on a bare one it degrades to `.unavailable`; both are visible states with
    /// a usable container. This guards against a regression that would make enabling sync fatal.
    func test_realCloudKitResolve_neverCrashes_andReturnsUsableContainer() throws {
        let url = Self.tempStoreURL()
        defer { Self.removeStore(at: url) }

        let resolved = try DataStore.resolve(preferCloudKit: true, url: url)
        XCTAssertNotEqual(resolved.syncState, .off, "requested CloudKit, so state must be active or unavailable")

        let context = ModelContext(resolved.container)
        context.insert(Preference(factKey: "pref:z", key: "k", value: "v"))
        XCTAssertNoThrow(try context.save())
    }

    /// Not requesting CloudKit yields a plain local-only container reported as `.off`.
    func test_cloudKitNotRequested_isOff() throws {
        let resolved = try DataStore.resolve(preferCloudKit: false, inMemory: true)
        XCTAssertEqual(resolved.syncState, .off)
        let context = ModelContext(resolved.container)
        context.insert(Preference(factKey: "pref:y", key: "k", value: "v"))
        XCTAssertNoThrow(try context.save())
    }

    /// The CloudKit container identifier follows the documented `iCloud.<bundleID>` convention and
    /// matches the entitlement/dashboard container the setup doc references.
    func test_cloudKitContainerIdentifier_matchesConvention() {
        XCTAssertEqual(DataStore.cloudKitContainerIdentifier, "iCloud.com.rajatarora.PersonalOpsAgent")
    }

    // MARK: - Helpers

    static func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pok-cloudkit-\(UUID().uuidString).store")
    }

    static func removeStore(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}

// MARK: - Intentionally CloudKit-incompatible models (test-local only)
//
// These exist ONLY to prove the validator catches violations; they are never added to the real
// schema. A uniqueness constraint and a non-optional relationship are the two most common ways a
// future phase could accidentally break CloudKit compatibility.

@Model
final class BadUniqueModel {
    @Attribute(.unique) var code: String = ""
    init(code: String = "") { self.code = code }
}

@Model
final class BadParent {
    // Non-optional to-many relationship — CloudKit forbids this.
    @Relationship(deleteRule: .cascade, inverse: \BadChild.parent)
    var children: [BadChild] = []
    init() {}
}

@Model
final class BadChild {
    var parent: BadParent?
    init() {}
}
