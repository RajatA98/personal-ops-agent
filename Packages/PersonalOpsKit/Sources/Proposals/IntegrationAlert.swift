import Foundation
import Core
import Integrations

/// # IntegrationAlert — a reconnect-needed integration surfaced in the Ops Inbox
///
/// Phase 2 flagged degraded/reconnect-required integrations only in Settings. Phase 4A also
/// surfaces them at the top of the Ops Inbox (PRD Integration Failure Modes: "creates an Ops
/// Inbox item or settings alert prompting reconnection").
///
/// ## Representation choice (documented)
/// A reconnect alert is **informational, not an executable Proposal**. Reconnecting requires an
/// OAuth consent flow the user drives in Settings — there is no state-mutating handler to run,
/// so modeling it as a Proposal would either invent a fake handler or leave an "approvable"
/// item that does nothing. Instead, alerts are a *separate, live-derived* Inbox section built
/// on demand from `IntegrationStatusStore`; they are never persisted and can never trigger a
/// handler. This keeps the invariant clean: **every executable Inbox item is a pending
/// Proposal, and approving one runs exactly one handler.** Alerts have no approve action — only
/// a "Reconnect in Settings" affordance.
public struct IntegrationAlert: Identifiable, Equatable, Sendable {
    public let source: DataSource
    public let title: String
    public let message: String

    public var id: DataSource { source }

    public init(source: DataSource, title: String, message: String) {
        self.source = source
        self.title = title
        self.message = message
    }
}

public enum IntegrationAlertBuilder {
    /// Build the current reconnect alerts from the status store. One alert per integration that
    /// needs re-consent (its token was revoked/expired and silent refresh failed).
    @MainActor
    public static func alerts(from store: IntegrationStatusStore) -> [IntegrationAlert] {
        store.ordered.compactMap { status in
            guard status.connection == .reconnectRequired else { return nil }
            let name = status.source.displayName
            return IntegrationAlert(
                source: status.source,
                title: "Reconnect \(name)",
                message: "\(name) needs to be reconnected — its access expired. "
                       + "Its data is absent from briefings until you reconnect in Settings.")
        }
    }
}
