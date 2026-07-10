import Foundation
import Core

/// Protocol-based fake for `HealthKitDataSource` (contract now lives in `Core`). Seeds a few
/// summaries for tests; the real device reader is `HealthKitClient` in `Integrations`.
public final class FakeHealthKitData: HealthKitDataSource, @unchecked Sendable {

    private let summaries: [HealthSummary]

    public init(summaries: [HealthSummary] = []) {
        self.summaries = summaries
    }

    public func summary(for range: ClosedRange<Date>) async throws -> [HealthSummary] {
        summaries.filter { range.contains($0.date) }
    }

    public static func seeded(referenceDate: Date = Date(timeIntervalSince1970: 1_000_000)) -> FakeHealthKitData {
        FakeHealthKitData(summaries: [
            HealthSummary(date: referenceDate.addingTimeInterval(-86400),
                          sleepHours: 6.2, restingHeartRate: 52, hrv: 68),
            HealthSummary(date: referenceDate,
                          sleepHours: 7.8, restingHeartRate: 49, hrv: 82)
        ])
    }

    /// Several nights of clearly *poor* recovery (short sleep, elevated RHR, depressed HRV) —
    /// drives the pacing adjuster to reduce load.
    public static func poorRecovery(endingAt referenceDate: Date = Date(timeIntervalSince1970: 1_000_000),
                                    nights: Int = 4) -> FakeHealthKitData {
        let summaries = (0..<nights).map { i in
            HealthSummary(date: referenceDate.addingTimeInterval(Double(-i) * 86_400),
                          sleepHours: 5.6, restingHeartRate: 61, hrv: 42)
        }
        return FakeHealthKitData(summaries: summaries)
    }

    /// Several nights of solid recovery (full sleep, low RHR, healthy HRV) — no reduction.
    public static func goodRecovery(endingAt referenceDate: Date = Date(timeIntervalSince1970: 1_000_000),
                                    nights: Int = 4) -> FakeHealthKitData {
        let summaries = (0..<nights).map { i in
            HealthSummary(date: referenceDate.addingTimeInterval(Double(-i) * 86_400),
                          sleepHours: 8.1, restingHeartRate: 47, hrv: 88)
        }
        return FakeHealthKitData(summaries: summaries)
    }
}

/// A fake that models HealthKit permission **denied**: authorization and reads both surface a
/// permission-withheld error. Used to prove the app degrades to "no influence, still fully
/// functional" (PRD Integration Failure Modes: "HealthKit permission denied: goals and pacing
/// continue to function without HealthKit influence").
public final class DenyingHealthKitData: HealthKitDataSource, @unchecked Sendable {
    public init() {}

    public func requestAuthorization() async throws {
        throw AppError.integration(.permissionWithheld(source: .healthKit))
    }

    public func summary(for range: ClosedRange<Date>) async throws -> [HealthSummary] {
        throw AppError.integration(.permissionWithheld(source: .healthKit))
    }
}
