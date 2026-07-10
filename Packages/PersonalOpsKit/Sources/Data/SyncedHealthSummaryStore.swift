import Foundation
import SwiftData
import Core

/// # SyncedHealthSummaryStore — the macOS HealthKit seam (Phase 7B)
///
/// The persistence + read adapter for the synced health-summary path. It plays two roles:
///
///   1. **On iPhone (writer):** `record(_:)` mirrors the summaries the real `HealthKitClient`
///      just read into durable `HealthSummaryRecord`s. Once CloudKit sync is on, those records
///      mirror to the user's private iCloud database automatically (they are CloudKit-shaped).
///
///   2. **On Mac (reader):** it conforms to `HealthKitDataSource` — the *exact* `\.healthKitSource`
///      seam Phase 3C introduced — so the Mac injects it in place of `HealthKitClient` and the
///      pure pacing engine (`PacedPlanner` / `HealthPacingCoordinator`) feeds off synced data
///      without ever linking HealthKit. `summary(for:)` reads the synced records back; the Mac
///      never reads HealthKit natively (LOCKED_DECISIONS #3/#10).
///
/// ## Why a `@ModelActor`
/// `HealthKitDataSource` is `Sendable` and its `summary(for:)` is `async`, and a `ModelContext`
/// may only be touched on its owning actor. `@ModelActor` synthesizes precisely that: a
/// `Sendable` actor owning a private `ModelContext` bound to the injected container. This mirrors
/// the `SwiftDataGmailMetadataStore` pattern (Phase 4B).
///
/// ## Dedupe convention (CloudKit-safe: no unique constraint)
/// `record` upserts by `dayKey` (find-or-update-else-insert) — the same write-time uniqueness
/// convention the rest of the schema uses. Re-recording the same day replaces its values rather
/// than duplicating the row. If two devices persist the same day and both rows arrive via sync,
/// `summary(for:)` collapses duplicate day keys keeping the most recently `recordedAt` one
/// (last-writer-wins), matching how `GmailMessageRecord` is reconciled.
@ModelActor
public actor SyncedHealthSummaryStore: HealthKitDataSource {

    /// Mirror recent `HealthSummary` values into durable, syncable records (iPhone writer path).
    /// Upserts by `dayKey` so a day is never duplicated on this device.
    public func record(_ summaries: [HealthSummary], recordedAt: Date = Date()) {
        for summary in summaries {
            let key = HealthSummaryRecord.dayKey(for: summary.date)
            let existing = try? modelContext.fetch(
                FetchDescriptor<HealthSummaryRecord>(
                    predicate: #Predicate { $0.dayKey == key }))
            if let record = existing?.first {
                record.date = summary.date
                record.sleepHours = summary.sleepHours
                record.restingHeartRate = summary.restingHeartRate
                record.hrv = summary.hrv
                record.recordedAt = recordedAt
            } else {
                modelContext.insert(HealthSummaryRecord(summary: summary, recordedAt: recordedAt))
            }
        }
        try? modelContext.save()
    }

    // MARK: HealthKitDataSource (Mac reader path)

    /// No-op: there is nothing to authorize when reading synced records (no HealthKit involved).
    /// The default extension already provides this; kept explicit for clarity on the Mac path.
    public func requestAuthorization() async throws {}

    /// Summaries whose `date` falls within `range`, read from the synced records. Duplicate day
    /// keys (possible after cross-device sync) collapse last-writer-wins by `recordedAt`.
    public func summary(for range: ClosedRange<Date>) async throws -> [HealthSummary] {
        let lower = range.lowerBound
        let upper = range.upperBound
        let records = (try? modelContext.fetch(
            FetchDescriptor<HealthSummaryRecord>(
                predicate: #Predicate { $0.date >= lower && $0.date <= upper }))) ?? []

        // Collapse duplicate days keeping the newest write (LWW), then sort by date.
        var newestByDay: [String: HealthSummaryRecord] = [:]
        for record in records {
            if let current = newestByDay[record.dayKey], current.recordedAt >= record.recordedAt {
                continue
            }
            newestByDay[record.dayKey] = record
        }
        return newestByDay.values
            .sorted { $0.date < $1.date }
            .map(\.summary)
    }
}

/// # MirroringHealthKitSource — write-through decorator for the iPhone (Phase 7B)
///
/// Wraps the real device `HealthKitDataSource` (`HealthKitClient` on iPhone) and, on every read,
/// mirrors the summaries into a `SyncedHealthSummaryStore` so they persist and sync to the Mac.
/// The iPhone injects this via `\.healthKitSource`; the Mac injects the bare
/// `SyncedHealthSummaryStore` (reader only). Reads are transparent — callers get exactly what the
/// wrapped source returns; the mirror write is best-effort and never fails the read.
public struct MirroringHealthKitSource: HealthKitDataSource {
    private let wrapped: any HealthKitDataSource
    private let store: SyncedHealthSummaryStore

    public init(wrapped: any HealthKitDataSource, store: SyncedHealthSummaryStore) {
        self.wrapped = wrapped
        self.store = store
    }

    public func requestAuthorization() async throws {
        try await wrapped.requestAuthorization()
    }

    public func summary(for range: ClosedRange<Date>) async throws -> [HealthSummary] {
        let summaries = try await wrapped.summary(for: range)
        if !summaries.isEmpty {
            await store.record(summaries)
        }
        return summaries
    }
}
