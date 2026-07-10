import SwiftUI
import SwiftData
import Core
import Data
import Integrations
import Signals

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
    /// Optional Gmail environment for the "Scan now" affordance. When absent (the current
    /// `RootView` call site, which is another agent's turf this phase), the scan section is
    /// simply hidden — everything else renders unchanged. Wiring it up is a one-line change at
    /// the `RootView`/App composition root (pass `integrations.gmail` + `integrations.gmailMetadata`).
    private let gmail: (any GmailAPI)?
    private let gmailMetadata: (any GmailMetadataStore)?
    /// Phase 7A: the resolved CloudKit sync state (off / on / unavailable). Defaults to `.off` so
    /// preview/older call sites render unchanged.
    private let syncState: CloudKitSyncState

    @Environment(\.modelContext) private var modelContext

    @State private var busy: Set<DataSource> = []
    @State private var errorMessage: String?
    @State private var scanning = false
    @State private var scanSummary: String?

    public init(status: IntegrationStatusStore,
                controller: any IntegrationController,
                gmail: (any GmailAPI)? = nil,
                gmailMetadata: (any GmailMetadataStore)? = nil,
                syncState: CloudKitSyncState = .off,
                now: @escaping () -> Date = { Date() }) {
        self.status = status
        self.controller = controller
        self.gmail = gmail
        self.gmailMetadata = gmailMetadata
        self.syncState = syncState
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

            if let gmail, let gmailMetadata {
                gmailScanSection(gmail: gmail, metadata: gmailMetadata)
            }

            syncSection

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

    /// # iCloud sync section (Phase 7A)
    ///
    /// Shows the CloudKit sync state (off / on / unavailable) and explains it in plain language.
    /// It is intentionally **read-only** here: the container is built once at launch from a Config
    /// flag (`CLOUDKIT_SYNC_ENABLED`), so turning sync on/off is a launch-time setting, not a live
    /// toggle (SwiftData can't re-attach CloudKit to a running container). SwiftData exposes no
    /// public "last synced at", so we don't invent one — we state what we can honestly know.
    @ViewBuilder
    private var syncSection: some View {
        Section("iCloud sync (iPhone ↔ Mac)") {
            HStack {
                Image(systemName: syncIcon).foregroundStyle(syncTint)
                Text("Sync").font(.headline)
                Spacer()
                Text(syncState.label).font(.caption).foregroundStyle(syncTint)
            }
            Text(syncExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if case .unavailable(let reason) = syncState {
                Label(reason, systemImage: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var syncIcon: String {
        switch syncState {
        case .off: return "icloud.slash"
        case .active: return "checkmark.icloud"
        case .unavailable: return "exclamationmark.icloud"
        }
    }

    private var syncTint: Color {
        switch syncState {
        case .off: return .secondary
        case .active: return .green
        case .unavailable: return .orange
        }
    }

    private var syncExplanation: String {
        switch syncState {
        case .off:
            return "Sync is off — your data stays on this device only. To sync between iPhone and Mac, "
                + "enable it in setup (see docs/CLOUDKIT_SETUP.md). This device works fully without sync."
        case .active:
            return "Sync is on. Changes flow between your iPhone and Mac automatically through your "
                + "private iCloud account — Apple never gives anyone else access. Nothing is sent to any "
                + "server we run."
        case .unavailable:
            return "Sync was requested but iCloud isn't available on this device right now, so the app is "
                + "running local-only. Your data is safe on this device and will sync once iCloud is back."
        }
    }

    /// "Scan now" — the foreground scan trigger. Runs the deterministic Gmail signal pipeline,
    /// which only ever creates *pending* Proposals in the Ops Inbox (never auto-acts).
    @ViewBuilder
    private func gmailScanSection(gmail: any GmailAPI, metadata: any GmailMetadataStore) -> some View {
        Section("Email signals") {
            Text("Scan recent email for plan-like items (meetings, confirmations) and add them to your Ops Inbox as proposals to review. Nothing is added to any calendar until you approve it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await scanNow(gmail: gmail, metadata: metadata) }
            } label: {
                HStack {
                    Label("Scan now", systemImage: "envelope.badge")
                    if scanning { Spacer(); ProgressView() }
                }
            }
            .disabled(scanning)
            if let scanSummary {
                Text(scanSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func scanNow(gmail: any GmailAPI, metadata: any GmailMetadataStore) async {
        scanning = true
        scanSummary = nil
        defer { scanning = false }
        let coordinator = GmailScanCoordinator(context: modelContext, gmail: gmail, metadataStore: metadata)
        do {
            let result = try await coordinator.scanNow()
            scanSummary = "Scanned \(result.scanned) message(s): \(result.proposed) new proposal(s), "
                + "\(result.dedupedByThread) already seen, \(result.suppressedByRejection) suppressed."
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't scan email right now. Please try again."
        }
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
