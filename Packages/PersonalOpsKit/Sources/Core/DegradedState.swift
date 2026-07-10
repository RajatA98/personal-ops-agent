import Foundation

/// User-visible degraded states. When a source fails or is withheld, the UI renders one
/// of these rather than pretending completeness (Safety Rule #6: degrade visibly).
public enum DegradedState: Equatable, Sendable {
    case sourceUnavailable(source: DataSource, reason: String)
    case sourceStale(source: DataSource, lastUpdated: Date)
    case permissionWithheld(source: DataSource)
    case reconnectRequired(source: DataSource)

    public var source: DataSource {
        switch self {
        case .sourceUnavailable(let s, _), .sourceStale(let s, _),
             .permissionWithheld(let s), .reconnectRequired(let s):
            return s
        }
    }

    /// Short label for a badge/inline notice.
    public var label: String {
        switch self {
        case .sourceUnavailable(let s, _): return "\(s.displayName) unavailable"
        case .sourceStale(let s, _): return "\(s.displayName) out of date"
        case .permissionWithheld(let s): return "\(s.displayName) off"
        case .reconnectRequired(let s): return "Reconnect \(s.displayName)"
        }
    }
}
