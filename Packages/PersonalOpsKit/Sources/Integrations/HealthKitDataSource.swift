import Foundation
import Core

/// Summarized sleep/recovery signals. Never raw HealthKit records (a local-only privacy
/// class per AGENT_DESIGN §3). Real read-only implementation lands in Phase 3C.
public struct HealthSummary: Equatable, Sendable {
    public let date: Date
    public let sleepHours: Double?
    public let restingHeartRate: Double?
    public let hrv: Double?

    public init(date: Date, sleepHours: Double? = nil,
                restingHeartRate: Double? = nil, hrv: Double? = nil) {
        self.date = date
        self.sleepHours = sleepHours
        self.restingHeartRate = restingHeartRate
        self.hrv = hrv
    }
}

public protocol HealthKitDataSource: Sendable {
    func summary(for range: ClosedRange<Date>) async throws -> [HealthSummary]
}
