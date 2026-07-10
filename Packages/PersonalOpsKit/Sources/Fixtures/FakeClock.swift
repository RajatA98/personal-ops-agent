import Foundation
import Core

/// Deterministic clock for tests. Every time-dependent behavior (freshness, slip
/// detection, retry, token expiry) is tested against this instead of wall-clock time.
public final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.current = now
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    public func set(to date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}
