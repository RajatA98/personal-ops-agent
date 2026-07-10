import SwiftUI
import Core
import Integrations

/// # Integrations / Settings screen (Phase 2)
///
/// The user-facing home for connection status. Per integration it shows: connection state,
/// source freshness ("synced 3m ago" / "out of date" / "never"), any degraded state, and a
/// Connect/Disconnect button. This is where a revoked-token *reconnect* state becomes visible
/// (PRD Integration Failure Modes) — the Ops Inbox that will also surface it doesn't exist
/// until Phase 4A, so Settings is the reconnect home for now.
///
/// The view is driven by an observable `IntegrationStatusStore` (state) plus an
/// `IntegrationController` (connect/disconnect actions), both injected — so it renders
/// identically against the live Google authenticator or a fixture in previews/tests.
public struct IntegrationsSettingsView: View {
    private let status: IntegrationStatusStore
    private let controller: any IntegrationController
    private let now: () -> Date

    @State private var busy: Set<DataSource> = []
    @State private var errorMessage: String?

    public init(status: IntegrationStatusStore,
                controller: any IntegrationController,
                now: @escaping () -> Date = { Date() }) {
        self.status = status
        self.controller = controller
        self.now = now
    }

    public var body: some View {
        List {
            Section {
                Text("Connect Google to let the agent read your real calendar and email, and manage its own \"Personal Ops Agent\" calendar. The agent never writes to your real calendars and never sends anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(status.ordered) { item in
                IntegrationRow(status: item,
                               isBusy: busy.contains(item.source),
                               now: now(),
                               connect: { await perform(item.source, connect: true) },
                               disconnect: { await perform(item.source, connect: false) })
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Integrations")
    }

    /// Calendar and Gmail are covered by one Google grant, so connect/disconnect act on the
    /// whole grant regardless of which row's button was tapped.
    private func perform(_ source: DataSource, connect: Bool) async {
        busy.insert(source)
        errorMessage = nil
        defer { busy.remove(source) }
        do {
            if connect { try await controller.connect() }
            else { try await controller.disconnect() }
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }
}

/// One integration's row: name, connection state, freshness, degraded notice, action button.
private struct IntegrationRow: View {
    let status: IntegrationStatus
    let isBusy: Bool
    let now: Date
    let connect: () async -> Void
    let disconnect: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(status.source.displayName).font(.headline)
                Spacer()
                connectionBadge
            }

            Text(freshnessText).font(.caption).foregroundStyle(.secondary)

            if let degraded = status.degraded {
                Label(degraded.label, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            actionButton
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch status.source {
        case .calendar: return "calendar"
        case .gmail: return "envelope"
        default: return "link"
        }
    }

    private var tint: Color {
        switch status.connection {
        case .connected: return .green
        case .reconnectRequired: return .orange
        case .disconnected: return .secondary
        }
    }

    @ViewBuilder private var connectionBadge: some View {
        switch status.connection {
        case .connected:
            Text("Connected").font(.caption).foregroundStyle(.green)
        case .reconnectRequired:
            Text("Reconnect needed").font(.caption).foregroundStyle(.orange)
        case .disconnected:
            Text("Not connected").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var freshnessText: String {
        switch status.freshness.status(asOf: now) {
        case .fresh, .stale:
            guard let age = status.freshness.age(asOf: now) else { return "Not synced yet" }
            let minutes = Int(age / 60)
            let label = minutes < 1 ? "just now" : "\(minutes)m ago"
            return status.freshness.status(asOf: now) == .stale
                ? "Last synced \(label) — out of date"
                : "Synced \(label)"
        case .unavailable:
            return "Not synced yet"
        case .permissionWithheld:
            return "Turned off"
        }
    }

    @ViewBuilder private var actionButton: some View {
        HStack {
            switch status.connection {
            case .connected:
                Button(role: .destructive) { Task { await disconnect() } } label: {
                    Text("Disconnect")
                }
            case .disconnected:
                Button { Task { await connect() } } label: { Text("Connect") }
            case .reconnectRequired:
                Button { Task { await connect() } } label: { Text("Reconnect") }
                    .tint(.orange)
            }
            if isBusy { ProgressView().padding(.leading, 8) }
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
    }
}

// MARK: - Preview

/// A no-network controller so the Settings screen renders in previews without live OAuth.
private struct PreviewIntegrationController: IntegrationController {
    func connect() async throws {}
    func disconnect() async throws {}
    func isConnected() async -> Bool { false }
}

#Preview {
    let store = IntegrationStatusStore()
    return NavigationStack {
        IntegrationsSettingsView(status: store, controller: PreviewIntegrationController())
    }
}
