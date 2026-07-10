import Foundation

/// The external/on-device data sources this app degrades against. Used by the error
/// model, degraded-state surface, and source-freshness display from Phase 2 onward.
public enum DataSource: String, Equatable, Sendable, Codable, CaseIterable {
    case calendar
    case gmail
    case healthKit
    case reasoning
    case iMessage
}
