import Foundation
import SwiftData
import Core

// MARK: - Fact-bearing memory models
//
// Every model here is `@Model final class … : MemoryEntity`.
//
// CloudKit-compatibility rules baked into every model in this phase (verified host-side by
// `CloudKitCompatibilityTests`, fully verifiable only on-device in Phase 7A):
//   • No `@Attribute(.unique)` anywhere — CloudKit forbids unique constraints. `appID`
//     uniqueness is a write-time convention, not a store constraint.
//   • Every stored attribute has a default value (via defaulted initializer parameters),
//     so CloudKit's "every property optional-or-defaulted" rule holds.
//   • `final class` so `makeRevisionCopy() -> Self` can construct a concrete instance.
//
// `revision`/`supersededAt`/`supersededByAppID`/`correctionReason` implement the
// append-only audit chain; see `MemoryEntity`.

/// A day's captured reality (from Evening Capture in Phase 3B).
@Model
public final class DailyLog: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.user.rawValue
    public var confidence: Double = 1.0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    /// The calendar day this log describes.
    public var logDate: Date = Date()
    /// Free-text summary of what actually happened.
    public var summary: String = ""

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .user,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        logDate: Date = Date(),
        summary: String = ""
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.logDate = logDate
        self.summary = summary
    }

    public func makeRevisionCopy() -> DailyLog {
        DailyLog(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            logDate: logDate, summary: summary
        )
    }
}

/// A promise/obligation the user has taken on (e.g. "call the dentist by Friday").
@Model
public final class Commitment: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.user.rawValue
    public var confidence: Double = 1.0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    public var title: String = ""
    public var dueDate: Date?
    public var isDone: Bool = false

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .user,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        title: String = "",
        dueDate: Date? = nil,
        isDone: Bool = false
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.title = title
        self.dueDate = dueDate
        self.isDone = isDone
    }

    public func makeRevisionCopy() -> Commitment {
        Commitment(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            title: title, dueDate: dueDate, isDone: isDone
        )
    }
}

/// A decision the user made ("I decided to decline the Acme offer").
@Model
public final class Decision: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.user.rawValue
    public var confidence: Double = 1.0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    /// What the decision was about ("acme_offer").
    public var topic: String = ""
    /// The choice made ("decline").
    public var choice: String = ""
    /// Why (free text).
    public var rationale: String = ""

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .user,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        topic: String = "",
        choice: String = "",
        rationale: String = ""
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.topic = topic
        self.choice = choice
        self.rationale = rationale
    }

    public func makeRevisionCopy() -> Decision {
        Decision(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            topic: topic, choice: choice, rationale: rationale
        )
    }
}

/// A stable user preference ("prefers morning workouts", "quiet hours after 10pm").
@Model
public final class Preference: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.user.rawValue
    public var confidence: Double = 1.0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    /// The preference subject ("workout_time_of_day").
    public var key: String = ""
    /// The preference value ("morning").
    public var value: String = ""

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .user,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        key: String = "",
        value: String = ""
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.key = key
        self.value = value
    }

    public func makeRevisionCopy() -> Preference {
        Preference(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            key: key, value: value
        )
    }
}

/// An unresolved thread of attention ("waiting to hear back from the recruiter").
@Model
public final class OpenLoop: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.user.rawValue
    public var confidence: Double = 1.0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    public var title: String = ""
    public var detail: String = ""
    public var isResolved: Bool = false
    /// If snoozed, when it should resurface.
    public var snoozedUntil: Date?

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .user,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        title: String = "",
        detail: String = "",
        isResolved: Bool = false,
        snoozedUntil: Date? = nil
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.title = title
        self.detail = detail
        self.isResolved = isResolved
        self.snoozedUntil = snoozedUntil
    }

    public func makeRevisionCopy() -> OpenLoop {
        OpenLoop(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            title: title, detail: detail, isResolved: isResolved, snoozedUntil: snoozedUntil
        )
    }
}

/// A recurring behavioral pattern the agent has noticed ("skips workouts after late nights").
@Model
public final class Pattern: MemoryEntity {
    public var appID: UUID = UUID()
    public var factKey: String = ""
    public var revision: Int = 1
    public var sourceRaw: String = MemorySource.inference.rawValue
    public var confidence: Double = 0.5
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var supersededAt: Date?
    public var supersededByAppID: UUID?
    public var correctionReason: String?

    public var name: String = ""
    public var detail: String = ""
    /// How many times the pattern has been observed (supports confidence over time).
    public var occurrences: Int = 1

    public init(
        appID: UUID = UUID(),
        factKey: String = "",
        revision: Int = 1,
        source: MemorySource = .inference,
        confidence: Double = 0.5,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByAppID: UUID? = nil,
        correctionReason: String? = nil,
        name: String = "",
        detail: String = "",
        occurrences: Int = 1
    ) {
        self.appID = appID
        self.factKey = factKey
        self.revision = revision
        self.sourceRaw = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.supersededAt = supersededAt
        self.supersededByAppID = supersededByAppID
        self.correctionReason = correctionReason
        self.name = name
        self.detail = detail
        self.occurrences = occurrences
    }

    public func makeRevisionCopy() -> Pattern {
        Pattern(
            factKey: factKey, revision: revision, source: source, confidence: confidence,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt,
            name: name, detail: detail, occurrences: occurrences
        )
    }
}
