import XCTest
import SwiftData
import Core
import Data
import Fixtures
@testable import Goals

/// # Phase 7B — synced HealthSummary → macOS pacing path
///
/// The Mac consumes HealthKit-derived pacing as **synced data** (LOCKED_DECISIONS #3/#10; Phase 3C
/// handoff): the iPhone mirrors HealthKit reads into `HealthSummaryRecord`s, CloudKit syncs them,
/// and the Mac injects a `SyncedHealthSummaryStore` at the `\.healthKitSource` seam so the pure
/// `PacedPlanner` runs off synced data with no HealthKit framework. These tests prove that whole
/// path host-side (device sync itself is paid-account/device-gated — see docs/CLOUDKIT_SETUP.md):
///   1. Store roundtrip: recorded summaries read back intact through the `HealthKitDataSource` API.
///   2. The synced adapter, fed into the pacing coordinator, produces the same visible influence
///      the native HealthKit source would — i.e. the Mac pacing path works end-to-end.
///   3. Upsert dedupes by day (no duplicate rows across re-records).
///   4. The iPhone write-through mirror persists what the real source returns.
final class SyncedHealthPacingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let training = PlaybookLibrary.triathlonTraining

    private func makeContainer() throws -> ModelContainer {
        try DataStore.makeContainer(inMemory: true)
    }

    private func poorSummaries(nights: Int = 4) -> [HealthSummary] {
        (0..<nights).map { i in
            HealthSummary(date: now.addingTimeInterval(Double(-i) * 86_400),
                          sleepHours: 5.6, restingHeartRate: 61, hrv: 42)
        }
    }

    // MARK: 1 — store roundtrip through the HealthKitDataSource API

    func test_recordedSummaries_readBackThroughDataSourceAPI() async throws {
        let store = SyncedHealthSummaryStore(modelContainer: try makeContainer())
        let input = poorSummaries(nights: 3)
        await store.record(input, recordedAt: now)

        let range = now.addingTimeInterval(-10 * 86_400)...now.addingTimeInterval(86_400)
        let readBack = try await store.summary(for: range)

        XCTAssertEqual(readBack.count, 3)
        // Sorted ascending by date; values survive the roundtrip.
        XCTAssertEqual(readBack.map(\.sleepHours), [5.6, 5.6, 5.6])
        XCTAssertEqual(readBack.last?.restingHeartRate, 61)
        XCTAssertEqual(readBack.last?.hrv, 42)
        XCTAssertEqual(readBack.last?.date, now)
    }

    // MARK: 2 — synced adapter feeds PacedPlanner and yields the SAME visible influence

    func test_syncedAdapter_drivesVisiblePacingInfluence_likeNativeSource() async throws {
        // Native source (what iPhone uses) — the control.
        let native = FakeHealthKitData.poorRecovery(endingAt: now, nights: 4)
        let nativePlan = await HealthPacingCoordinator(source: native, lookback: 14 * 86_400)
            .generatePlan(playbook: training, answers: IntakeAnswers(), goalTitle: "Ironman 70.3",
                          now: now, targetDate: now.addingTimeInterval(28 * 86_400),
                          influenceEnabled: true)
        let nativeInfluenced = nativePlan.tasks.filter { $0.pacing != nil }
        XCTAssertFalse(nativeInfluenced.isEmpty, "control: native poor recovery must pace tasks")

        // Synced source (what Mac uses): record the SAME summaries into the store, then plan off it.
        let store = SyncedHealthSummaryStore(modelContainer: try makeContainer())
        await store.record(poorSummaries(nights: 4), recordedAt: now)
        let syncedPlan = await HealthPacingCoordinator(source: store, lookback: 14 * 86_400)
            .generatePlan(playbook: training, answers: IntakeAnswers(), goalTitle: "Ironman 70.3",
                          now: now, targetDate: now.addingTimeInterval(28 * 86_400),
                          influenceEnabled: true)
        let syncedInfluenced = syncedPlan.tasks.filter { $0.pacing != nil }

        XCTAssertFalse(syncedInfluenced.isEmpty,
                       "Mac synced-data path must produce pacing influence")
        // The Mac path is equivalent to the native path: same paced rule keys, same visible label.
        XCTAssertEqual(Set(syncedInfluenced.map(\.ruleKey)), Set(nativeInfluenced.map(\.ruleKey)))
        XCTAssertTrue(syncedInfluenced.allSatisfy { $0.pacing?.isHealthKitInfluenced == true })
        XCTAssertEqual(syncedInfluenced.first?.pacing?.label, "HealthKit-influenced")
    }

    // MARK: 3 — upsert dedupes by day

    func test_recordSameDayTwice_upsertsInPlace_noDuplicateRows() async throws {
        let container = try makeContainer()
        let store = SyncedHealthSummaryStore(modelContainer: container)

        await store.record([HealthSummary(date: now, sleepHours: 5.6)], recordedAt: now)
        // A later, corrected read of the same day (more sleep counted).
        await store.record([HealthSummary(date: now, sleepHours: 6.9)],
                           recordedAt: now.addingTimeInterval(3600))

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<HealthSummaryRecord>())
        XCTAssertEqual(rows.count, 1, "same day must upsert, not duplicate")

        let readBack = try await store.summary(for: now.addingTimeInterval(-86_400)...now.addingTimeInterval(86_400))
        XCTAssertEqual(readBack.first?.sleepHours, 6.9, "newest write wins")
    }

    // MARK: 4 — iPhone write-through mirror persists what the real source returns

    func test_mirroringSource_persistsReadsForSync() async throws {
        let store = SyncedHealthSummaryStore(modelContainer: try makeContainer())
        let real = FakeHealthKitData.poorRecovery(endingAt: now, nights: 4)
        let mirror = MirroringHealthKitSource(wrapped: real, store: store)

        let range = now.addingTimeInterval(-10 * 86_400)...now.addingTimeInterval(86_400)
        let returned = try await mirror.summary(for: range)
        XCTAssertEqual(returned.count, 4, "mirror is transparent — returns exactly what the source read")

        // The store now holds the mirrored records (what would sync to the Mac).
        let synced = try await store.summary(for: range)
        XCTAssertEqual(synced.count, 4)
        XCTAssertEqual(synced.map(\.sleepHours), returned.sorted { $0.date < $1.date }.map(\.sleepHours))
    }
}
