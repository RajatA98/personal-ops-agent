import Foundation
import Core
#if canImport(HealthKit)
import HealthKit
#endif

/// # HealthKitClient — real, read-only HealthKit reader (Phase 3C)
///
/// The device-backed implementation of `Core.HealthKitDataSource`. It reads three
/// recovery-adjacent signals — **sleep duration**, **resting heart rate**, and **HRV (SDNN)** —
/// and summarizes them into `HealthSummary` values. It is *read-only by construction*: it
/// requests only HealthKit **read** authorization and exposes no write path (Safety model —
/// raw HealthKit data is a local-only privacy class, PRD "Data Boundaries").
///
/// Compilation & testing strategy (mirrors Phase 2's live-OAuth approach): the real reader is
/// live-capable and compiles into the iOS app, but real reads require the HealthKit entitlement
/// and a physical device with Health data. So `swift test` never exercises this type — the pure
/// pacing engine is verified against `FakeHealthKitData` instead, and everything here is guarded
/// with `#if canImport(HealthKit)` plus a graceful `.unavailable` fallback so the type always
/// exists for composition and the host build stays green.
///
/// **Only a device build can verify**: the real permission sheet, that denial leaves reads
/// empty (not crashing), and that real sleep/RHR/HRV values flow into pacing.
public final class HealthKitClient: HealthKitDataSource, @unchecked Sendable {

    public init() {}

    #if canImport(HealthKit)

    private let store = HKHealthStore()

    /// The read-only set of types we request. Sleep is a category type; RHR and HRV are
    /// quantity types. No share (write) types are ever requested.
    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.insert(rhr) }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
        return types
    }

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw AppError.integration(.unavailable(source: .healthKit, reason: "HealthKit not available on this device"))
        }
        // `toShare` is empty — we never write. This makes read-only structural, not conventional.
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    public func summary(for range: ClosedRange<Date>) async throws -> [HealthSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }

        // Read each signal independently; a missing/denied type simply contributes nothing
        // (empty), never fails the whole read — callers treat absence as "no influence."
        async let sleepByDay = sleepHoursByDay(range)
        async let rhrByDay = dailyAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), range: range)
        async let hrvByDay = dailyAverage(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), range: range)

        let sleep = await sleepByDay
        let rhr = await rhrByDay
        let hrv = await hrvByDay

        let days = Set(sleep.keys).union(rhr.keys).union(hrv.keys).sorted()
        return days.map { day in
            HealthSummary(date: day, sleepHours: sleep[day],
                          restingHeartRate: rhr[day], hrv: hrv[day])
        }
    }

    // MARK: - Queries (each returns per-day values keyed by start-of-day)

    /// Total asleep hours per day from `.sleepAnalysis` category samples (iOS 16+ "asleep*"
    /// values, with a fallback to the legacy `.asleep` value).
    private func sleepHoursByDay(_ range: ClosedRange<Date>) async -> [Date: Double] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound)
        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                cont.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        let cal = Calendar.current
        var secondsByDay: [Date: Double] = [:]
        for s in samples where Self.isAsleep(s) {
            let day = cal.startOfDay(for: s.endDate)
            secondsByDay[day, default: 0] += s.endDate.timeIntervalSince(s.startDate)
        }
        return secondsByDay.mapValues { $0 / 3600.0 }
    }

    /// Min deployment targets (iOS 18 / macOS 15) guarantee the granular "asleep*" values, so
    /// there's no need for the deprecated legacy `.asleep`.
    private static func isAsleep(_ sample: HKCategorySample) -> Bool {
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        ]
        return asleepValues.contains(sample.value)
    }

    /// Average of a quantity type per day (start-of-day keyed).
    private func dailyAverage(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                              range: ClosedRange<Date>) async -> [Date: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound)
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        let cal = Calendar.current
        var sums: [Date: Double] = [:]
        var counts: [Date: Int] = [:]
        for s in samples {
            let day = cal.startOfDay(for: s.startDate)
            sums[day, default: 0] += s.quantity.doubleValue(for: unit)
            counts[day, default: 0] += 1
        }
        var out: [Date: Double] = [:]
        for (day, total) in sums { out[day] = total / Double(counts[day] ?? 1) }
        return out
    }

    #else

    /// Non-HealthKit platforms: the reader exists for composition but has nothing to read.
    public func requestAuthorization() async throws {
        throw AppError.integration(.unavailable(source: .healthKit, reason: "HealthKit unavailable on this platform"))
    }

    public func summary(for range: ClosedRange<Date>) async throws -> [HealthSummary] { [] }

    #endif
}
