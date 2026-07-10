import Foundation

/// Abstract clock so time-dependent logic (freshness, slip detection, retry) is testable
/// with a deterministic `FakeClock` (see the Fixtures target). Production uses `SystemClock`.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}
