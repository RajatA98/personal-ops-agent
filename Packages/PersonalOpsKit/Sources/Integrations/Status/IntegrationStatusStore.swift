import Foundation
import Core

/// The connection state of one integration, as shown in Settings and (from Phase 4A) the
/// Ops Inbox.
public enum ConnectionState: Equatable, Sendable {
    /// Authorized and usable.
    case connected
    /// Never authorized, or explicitly disconnected by the user.
    case disconnected
    /// Was connected but the token was revoked/expired and silent refresh failed — the user
    /// must re-consent. This is the visible "reconnect" state (PRD Integration Failure Modes).
    case reconnectRequired
}

/// Everything the UI needs to render one integration row: its connection state, how fresh
/// its data is, and any active degraded state.
public struct IntegrationStatus: Equatable, Sendable, Identifiable {
    public let source: DataSource
    public var connection: ConnectionState
    public var freshness: SourceFreshness
    public var degraded: DegradedState?

    public var id: DataSource { source }

    public init(source: DataSource,
                connection: ConnectionState = .disconnected,
                freshness: SourceFreshness,
                degraded: DegradedState? = nil) {
        self.source = source
        self.connection = connection
        self.freshness = freshness
        self.degraded = degraded
    }
}

/// The write side of integration status, used by the authenticator and API clients to report
/// connection/sync/degradation events. `Sendable` and `async` so background transport code
/// can report into a `@MainActor` store without knowing it is main-actor-isolated.
///
/// Phase 4A reads the resulting `IntegrationStatusStore` to surface reconnect prompts as Ops
/// Inbox items; in Phase 2 the Settings screen is the only reader.
public protocol IntegrationStatusReporting: Sendable {
    func reportConnected(_ source: DataSource, syncedAt: Date?, threshold: TimeInterval) async
    func reportSynced(_ source: DataSource, at date: Date, threshold: TimeInterval) async
    func reportDegraded(_ source: DataSource, _ state: DegradedState) async
    func reportDisconnected(_ source: DataSource) async
}

/// Observable, single source of truth for per-integration status. `@MainActor` because
/// SwiftUI observes it; background code reports through the `IntegrationStatusReporting`
/// async methods, which hop to the main actor.
@MainActor
@Observable
public final class IntegrationStatusStore: IntegrationStatusReporting {

    /// The integrations this app manages. Reasoning/iMessage are not OAuth integrations, so
    /// the Settings surface tracks Calendar and Gmail (both covered by one Google grant).
    public static let managedSources: [DataSource] = [.calendar, .gmail]

    public private(set) var statuses: [DataSource: IntegrationStatus]

    private let defaultThreshold: TimeInterval

    public init(sources: [DataSource] = IntegrationStatusStore.managedSources,
                stalenessThreshold: TimeInterval = 15 * 60) {
        self.defaultThreshold = stalenessThreshold
        var initial: [DataSource: IntegrationStatus] = [:]
        for source in sources {
            initial[source] = IntegrationStatus(
                source: source,
                connection: .disconnected,
                freshness: SourceFreshness(source: source,
                                           lastSuccessfulSync: nil,
                                           stalenessThreshold: stalenessThreshold))
        }
        self.statuses = initial
    }

    /// Ordered list for the UI (stable by `managedSources` order).
    public var ordered: [IntegrationStatus] {
        Self.managedSources.compactMap { statuses[$0] }
    }

    public func status(for source: DataSource) -> IntegrationStatus? { statuses[source] }

    // MARK: IntegrationStatusReporting

    public func reportConnected(_ source: DataSource, syncedAt: Date?, threshold: TimeInterval) async {
        update(source) {
            $0.connection = .connected
            $0.degraded = nil
            $0.freshness = SourceFreshness(source: source,
                                           lastSuccessfulSync: syncedAt,
                                           stalenessThreshold: threshold)
        }
    }

    public func reportSynced(_ source: DataSource, at date: Date, threshold: TimeInterval) async {
        update(source) {
            $0.connection = .connected
            $0.degraded = nil
            $0.freshness = SourceFreshness(source: source,
                                           lastSuccessfulSync: date,
                                           stalenessThreshold: threshold)
        }
    }

    public func reportDegraded(_ source: DataSource, _ state: DegradedState) async {
        update(source) {
            $0.degraded = state
            if case .reconnectRequired = state { $0.connection = .reconnectRequired }
        }
    }

    public func reportDisconnected(_ source: DataSource) async {
        update(source) {
            $0.connection = .disconnected
            $0.degraded = nil
            $0.freshness = SourceFreshness(source: source,
                                           lastSuccessfulSync: nil,
                                           stalenessThreshold: defaultThreshold)
        }
    }

    private func update(_ source: DataSource, _ mutate: (inout IntegrationStatus) -> Void) {
        guard var current = statuses[source] else { return }
        mutate(&current)
        statuses[source] = current
    }
}
