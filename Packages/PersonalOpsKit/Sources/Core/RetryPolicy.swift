import Foundation

/// Retry-policy convention used by every network/integration call from Phase 2 onward.
/// Exponential backoff with optional full jitter. Callers combine this with
/// `AppError.isRetryable` — a non-retryable error is never retried regardless of policy.
public struct RetryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let multiplier: Double
    public let jitter: Bool

    public init(maxAttempts: Int, baseDelay: TimeInterval, multiplier: Double, jitter: Bool) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.jitter = jitter
    }

    /// Nominal (or jittered) delay before the given 1-based attempt number.
    /// Attempt 1 = `baseDelay`, attempt 2 = `baseDelay * multiplier`, etc.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let n = max(1, attempt)
        let nominal = baseDelay * pow(multiplier, Double(n - 1))
        guard jitter else { return nominal }
        // Full jitter over the growth introduced by this attempt: [prev, nominal].
        let previous = n == 1 ? 0 : baseDelay * pow(multiplier, Double(n - 2))
        let lower = max(previous, baseDelay == 0 ? 0 : min(previous, nominal))
        return TimeInterval.random(in: min(lower, nominal)...nominal)
    }

    /// Whether another attempt is permitted after the given 1-based attempt just failed.
    public func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }

    /// Sensible defaults.
    public static let standard = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, multiplier: 2.0, jitter: true)
    public static let aggressive = RetryPolicy(maxAttempts: 5, baseDelay: 0.25, multiplier: 2.0, jitter: true)
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, multiplier: 1, jitter: false)
}
