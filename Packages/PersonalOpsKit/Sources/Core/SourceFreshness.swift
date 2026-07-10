import Foundation

/// Source-freshness convention. Every data source the briefing draws on carries one of
/// these so the UI can show "Calendar synced 3m ago / Gmail out of date" (PROJECT_PLAN
/// Phase 3B) rather than implying data is current when it isn't.
public struct SourceFreshness: Equatable, Sendable {

    public enum Status: Equatable, Sendable {
        case fresh
        case stale
        case unavailable          // never successfully synced
        case permissionWithheld   // user turned the source off
    }

    public let source: DataSource
    public let lastSuccessfulSync: Date?
    public let stalenessThreshold: TimeInterval
    public let permissionWithheld: Bool

    public init(source: DataSource,
                lastSuccessfulSync: Date?,
                stalenessThreshold: TimeInterval,
                permissionWithheld: Bool = false) {
        self.source = source
        self.lastSuccessfulSync = lastSuccessfulSync
        self.stalenessThreshold = stalenessThreshold
        self.permissionWithheld = permissionWithheld
    }

    public func status(asOf now: Date) -> Status {
        if permissionWithheld { return .permissionWithheld }
        guard let last = lastSuccessfulSync else { return .unavailable }
        return now.timeIntervalSince(last) <= stalenessThreshold ? .fresh : .stale
    }

    public func isDegraded(asOf now: Date) -> Bool {
        status(asOf: now) != .fresh
    }

    /// Age of the data as of `now`, or nil if never synced.
    public func age(asOf now: Date) -> TimeInterval? {
        lastSuccessfulSync.map { now.timeIntervalSince($0) }
    }
}
