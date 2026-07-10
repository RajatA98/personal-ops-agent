import Foundation
import SwiftData
import Core

/// # HealthSummaryRecord — the syncable, persisted health summary (Phase 7B)
///
/// A persisted, CloudKit-syncable copy of a day's summarized sleep/recovery signals
/// (`HealthSummary`, the `Core` boundary type). This is the seam that lets the **macOS app
/// consume HealthKit-derived pacing as synced data** rather than reading HealthKit natively
/// (LOCKED_DECISIONS #3/#10; Phase 3C's handoff): the iPhone reads HealthKit, mirrors the
/// summaries into these records, CloudKit syncs them to the Mac, and the Mac's
/// `SyncedHealthSummaryStore` feeds them straight into the pure `PacedPlanner` — no HealthKit
/// framework on the Mac at all.
///
/// Like `GmailMessageRecord`, this is **operational metadata, not a corrigible memory fact** —
/// there is nothing to "correct" about a night's measured sleep. It is a plain `@Model` that
/// still follows the Phase 1 CloudKit-compatible conventions:
///   • a stable `appID` (the CloudKit-safe app-level identity convention),
///   • **no unique constraints** (per-day uniqueness by `dayKey` is a write-time upsert
///     convention, exactly like `appID`/`messageID` elsewhere), and
///   • every attribute optional-or-defaulted.
///
/// ## Data boundary (PRD Data Boundaries)
/// Stores only **summarized** signals (sleep hours, resting heart rate, HRV) — never raw
/// HealthKit samples. Raw samples are a `local-only` privacy class that never leaves the device;
/// a per-night summary is the coarsened form the pacing engine already consumes. Syncing the
/// summary to the user's *own* Mac via their *own* private CloudKit database keeps it inside the
/// same trust boundary (the user's iCloud account), consistent with the no-backend decision.
@Model
public final class HealthSummaryRecord: AppEntity {
    public var appID: UUID = UUID()
    /// Stable per-day identity used for upsert dedupe (a write-time convention, not a DB
    /// constraint — CloudKit forbids unique attributes). Format: `yyyy-MM-dd` in UTC.
    public var dayKey: String = ""
    /// The night/day these signals describe (typically the wake date).
    public var date: Date = Date(timeIntervalSince1970: 0)
    /// Hours of sleep for the night ending on `date`.
    public var sleepHours: Double?
    /// Resting heart rate (bpm).
    public var restingHeartRate: Double?
    /// Heart-rate variability (SDNN, ms).
    public var hrv: Double?
    /// When this record was written (the mirroring timestamp). Used as the last-writer-wins
    /// tiebreaker if two devices happen to persist the same day.
    public var recordedAt: Date = Date(timeIntervalSince1970: 0)

    public init(appID: UUID = UUID(),
                dayKey: String = "",
                date: Date = Date(timeIntervalSince1970: 0),
                sleepHours: Double? = nil,
                restingHeartRate: Double? = nil,
                hrv: Double? = nil,
                recordedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.appID = appID
        self.dayKey = dayKey
        self.date = date
        self.sleepHours = sleepHours
        self.restingHeartRate = restingHeartRate
        self.hrv = hrv
        self.recordedAt = recordedAt
    }

    /// The `yyyy-MM-dd` (UTC) day key for a date — the stable per-day identity used for dedupe.
    /// A fresh formatter per call (`DateFormatter` is not `Sendable`); cheap at single-user scale.
    public static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Build a record from the `Core` boundary type.
    public convenience init(summary: HealthSummary, recordedAt: Date) {
        self.init(dayKey: Self.dayKey(for: summary.date),
                  date: summary.date,
                  sleepHours: summary.sleepHours,
                  restingHeartRate: summary.restingHeartRate,
                  hrv: summary.hrv,
                  recordedAt: recordedAt)
    }

    /// Project back to the pure `Core` boundary type the pacing engine consumes.
    public var summary: HealthSummary {
        HealthSummary(date: date, sleepHours: sleepHours,
                      restingHeartRate: restingHeartRate, hrv: hrv)
    }
}
