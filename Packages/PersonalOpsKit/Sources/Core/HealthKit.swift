import Foundation

/// # HealthKit contract (pure — no HealthKit framework dependency)
///
/// This is the *boundary type* for sleep/recovery signals, kept in `Core` so both the real
/// HealthKit-backed reader (in `Integrations`, which links the HealthKit framework) and the
/// pure goal-pacing engine (in `Goals`) can share it **without** `Goals` depending on
/// `Integrations`. Keeping the contract here is what lets the pacing adjuster stay pure and
/// host-testable while the real device reader lives behind the same protocol.
///
/// `HealthSummary` is a *summarized* signal, never a raw HealthKit sample — raw HealthKit data
/// is a `local-only` privacy class (PRD "Data Boundaries") that must never leave the device.

/// A day's summarized sleep/recovery signals. All fields optional: a source may only have some.
public struct HealthSummary: Equatable, Sendable {
    /// The night/day these signals describe (typically the wake date).
    public let date: Date
    /// Hours of sleep for the night ending on `date`.
    public let sleepHours: Double?
    /// Resting heart rate (bpm). Elevated RHR is a recovery-cost signal.
    public let restingHeartRate: Double?
    /// Heart-rate variability (SDNN, ms). Depressed HRV is a recovery-cost signal.
    public let hrv: Double?

    public init(date: Date, sleepHours: Double? = nil,
                restingHeartRate: Double? = nil, hrv: Double? = nil) {
        self.date = date
        self.sleepHours = sleepHours
        self.restingHeartRate = restingHeartRate
        self.hrv = hrv
    }
}

/// A read-only source of summarized health signals. The real implementation (`HealthKitClient`
/// in `Integrations`) reads sleep/RHR/HRV via HealthKit on a real device; fakes drive tests.
///
/// Read-only by construction: the protocol exposes no write path, and the real reader requests
/// only *read* authorization. There is deliberately no way to write HealthKit data.
public protocol HealthKitDataSource: Sendable {
    /// Request read authorization for the sleep/recovery types this app uses. Idempotent.
    /// On platforms/devices without HealthKit, throws `AppError.integration(.unavailable(...))`;
    /// if the user denies, subsequent reads simply return no data (HealthKit does not reveal
    /// denial for privacy) or throw `.permissionWithheld` — callers must treat both as "absent."
    func requestAuthorization() async throws
    /// Summaries whose `date` falls within `range`. Returns `[]` when nothing is available
    /// (no permission, no data) rather than failing the caller's flow.
    func summary(for range: ClosedRange<Date>) async throws -> [HealthSummary]
}

public extension HealthKitDataSource {
    /// Default no-op so fakes and read-only callers need not implement authorization.
    func requestAuthorization() async throws {}
}
