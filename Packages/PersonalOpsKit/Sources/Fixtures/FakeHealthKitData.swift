import Foundation
import Core
import Integrations

/// Protocol-based fake for `HealthKitDataSource` with minimal seed summaries. Real
/// read-only implementation lands in Phase 3C; nothing else hard-depends on it.
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
}
