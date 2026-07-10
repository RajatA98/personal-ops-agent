import Foundation
import SwiftData

/// # CloudKitSchemaValidator — the schema regression tripwire (Phase 7A)
///
/// SwiftData's CloudKit integration (`NSPersistentCloudKitContainer` under the hood) imposes hard
/// schema constraints. A schema that violates any of them will *fail to sync on-device* — and,
/// worse, that failure only shows up on an iCloud-entitled build, long after the offending field
/// was merged. This validator walks the live `Schema` reflectively and reports every violation it
/// can detect **host-side**, so a future phase that adds a CloudKit-incompatible field trips the
/// wire in plain `swift test` instead of on a device weeks later.
///
/// ## What it checks (all reflectable from `Schema.Entity`, no device required)
///   1. **No uniqueness constraints.** CloudKit has no notion of a unique key; SwiftData refuses
///      to mirror an entity that declares one. (Our uniqueness — `appID`, `factKey`, `messageID` —
///      is a *write-time convention*, never a store constraint.)
///   2. **Every relationship is optional.** CloudKit cannot guarantee a related record has synced
///      before its owner, so every relationship (to-one and to-many) must be optional.
///   3. **Every relationship has an inverse.** CloudKit requires a defined inverse on relationships
///      it mirrors; SwiftData's own CloudKit validation enforces this too.
///
/// ## What it deliberately does NOT check
/// The "every non-optional attribute has a default" rule is *not* reliably reflectable —
/// `Schema.Attribute` does not surface the Swift initializer default in a dependable way across
/// OS versions, so asserting on it would produce false positives on perfectly valid models. That
/// rule is instead proven behaviourally by `CloudKitCompatibilityTests.test_everyModel_persistsWithAllDefaultValues`
/// (default-construct + save every model) and, ultimately, by the on-device CloudKit container
/// build in the Phase 7A device checklist. Reflective checks here are the ones that are both
/// reliable and cheap.
public enum CloudKitSchemaValidator {

    /// A single CloudKit-compatibility violation found in a schema.
    public struct Violation: Equatable, CustomStringConvertible {
        public enum Kind: String, Equatable {
            case uniquenessConstraint
            case nonOptionalRelationship
            case relationshipMissingInverse
        }
        public let entity: String
        public let property: String
        public let kind: Kind

        public var description: String {
            switch kind {
            case .uniquenessConstraint:
                return "\(entity).\(property): declares a uniqueness constraint — CloudKit forbids these (use a write-time uniqueness convention instead)."
            case .nonOptionalRelationship:
                return "\(entity).\(property): relationship is non-optional — CloudKit requires every relationship to be optional."
            case .relationshipMissingInverse:
                return "\(entity).\(property): relationship has no inverse — CloudKit requires a defined inverse."
            }
        }
    }

    /// Walk a schema and return every CloudKit-incompatibility it can detect host-side.
    /// An empty result means the schema passes every reflectable CloudKit constraint.
    public static func violations(in schema: Schema) -> [Violation] {
        var found: [Violation] = []
        for entity in schema.entities {
            // 1. No uniqueness constraints.
            for constraint in entity.uniquenessConstraints {
                found.append(Violation(entity: entity.name,
                                       property: constraint.joined(separator: "+"),
                                       kind: .uniquenessConstraint))
            }
            // 2 & 3. Relationships optional, with an inverse.
            for relationship in entity.relationships {
                if !relationship.isOptional {
                    found.append(Violation(entity: entity.name,
                                           property: relationship.name,
                                           kind: .nonOptionalRelationship))
                }
                if relationship.inverseName == nil {
                    found.append(Violation(entity: entity.name,
                                           property: relationship.name,
                                           kind: .relationshipMissingInverse))
                }
            }
        }
        return found
    }
}
