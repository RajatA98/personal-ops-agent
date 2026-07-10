import SwiftUI
import SwiftData
import Core
import Data
import Integrations
import Proposals

/// # Ops Inbox — the "propose, don't auto-act" review surface
///
/// Lists pending Proposals with per-type confirmation copy and the full action set (approve /
/// dismiss / snooze / mark-as-wrong), plus batch approve/dismiss. Reconnect-needed integrations
/// appear as an informational section at the top (never as approvable proposals — see
/// `IntegrationAlert`). All state changes go through `ProposalEngine`, so the Inbox is the ONLY
/// place a Proposal becomes an action.
@MainActor
@Observable
final class OpsInboxModel {
    private let engine: ProposalEngine
    private let statusStore: IntegrationStatusStore

    var pending: [Proposal] = []
    var alerts: [IntegrationAlert] = []
    var selection: Set<UUID> = []
    var errorMessage: String?

    init(context: ModelContext, integrations: IntegrationsEnvironment, clock: any Clock = SystemClock()) {
        self.engine = ProposalEngine(context: context, clock: clock, calendar: integrations.calendar)
        self.statusStore = integrations.status
    }

    func reload() {
        _ = try? engine.expirePendingPastDue()
        _ = try? engine.resurfaceDueSnoozed()
        pending = (try? engine.pendingProposals()) ?? []
        alerts = IntegrationAlertBuilder.alerts(from: statusStore)
        selection = selection.intersection(Set(pending.map(\.appID)))
    }

    func copy(for proposal: Proposal) -> ProposalConfirmationCopy {
        ProposalConfirmationCopy.copy(for: proposal.proposalType)
    }

    func approve(_ proposal: Proposal) async {
        do { _ = try await engine.approve(proposal); reload() }
        catch { errorMessage = describe(error) }
    }

    func dismiss(_ proposal: Proposal) {
        do { try engine.dismiss(proposal); reload() } catch { errorMessage = describe(error) }
    }

    func snooze(_ proposal: Proposal, days: Int = 1) {
        do { try engine.snooze(proposal, until: Date().addingTimeInterval(Double(days) * 86_400)); reload() }
        catch { errorMessage = describe(error) }
    }

    func markWrong(_ proposal: Proposal) {
        do { _ = try engine.markAsWrong(proposal); reload() } catch { errorMessage = describe(error) }
    }

    // MARK: Batch

    private var selectedProposals: [Proposal] { pending.filter { selection.contains($0.appID) } }

    func approveSelected() async {
        let targets = selectedProposals.isEmpty ? pending : selectedProposals
        do { _ = try await engine.approveBatch(targets); reload() } catch { errorMessage = describe(error) }
    }

    func dismissSelected() {
        let targets = selectedProposals.isEmpty ? pending : selectedProposals
        do { try engine.dismissBatch(targets); reload() } catch { errorMessage = describe(error) }
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? ProposalError {
            switch e {
            case .integrationUnavailable: return "That integration isn't connected. Reconnect it in Settings, then try again."
            case .expired: return "That proposal expired and was dropped."
            case .targetNotFound: return "The item this proposal referred to no longer exists."
            case .malformedPayload: return "This proposal is malformed and can't be run."
            case .noHandler(let t): return "No handler for \(t.rawValue)."
            case .notPending(let s): return "This proposal is already \(s.rawValue)."
            }
        }
        return "Something went wrong. The proposal is still pending — nothing was changed."
    }
}

public struct OpsInboxView: View {
    private let integrations: IntegrationsEnvironment
    @Environment(\.modelContext) private var modelContext
    @State private var model: OpsInboxModel?

    public init(integrations: IntegrationsEnvironment) {
        self.integrations = integrations
    }

    public var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Ops Inbox")
        .onAppear {
            if model == nil {
                model = OpsInboxModel(context: modelContext, integrations: integrations)
            }
            model?.reload()
        }
    }

    @ViewBuilder
    private func content(_ model: OpsInboxModel) -> some View {
        List {
            if !model.alerts.isEmpty {
                Section("Needs attention") {
                    ForEach(model.alerts) { alert in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(alert.title, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(alert.message).font(.footnote).foregroundStyle(.secondary)
                            Text("Reconnect in the Integrations tab.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.pending.isEmpty {
                Section {
                    ContentUnavailableView("Inbox zero",
                                           systemImage: "tray",
                                           description: Text("No proposals waiting for your review."))
                }
            } else {
                Section("Pending — \(model.pending.count)") {
                    ForEach(model.pending) { proposal in
                        proposalRow(proposal, model: model)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.pending.isEmpty {
                HStack {
                    Button {
                        Task { await model.approveSelected() }
                    } label: { Label(batchApproveLabel(model), systemImage: "checkmark.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button(role: .destructive) {
                        model.dismissSelected()
                    } label: { Label(batchDismissLabel(model), systemImage: "xmark.circle") }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(.thinMaterial)
            }
        }
        .alert("Couldn't complete that",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func batchApproveLabel(_ model: OpsInboxModel) -> String {
        model.selection.isEmpty ? "Approve all" : "Approve \(model.selection.count)"
    }
    private func batchDismissLabel(_ model: OpsInboxModel) -> String {
        model.selection.isEmpty ? "Dismiss all" : "Dismiss \(model.selection.count)"
    }

    @ViewBuilder
    private func proposalRow(_ proposal: Proposal, model: OpsInboxModel) -> some View {
        let copy = model.copy(for: proposal)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    if model.selection.contains(proposal.appID) { model.selection.remove(proposal.appID) }
                    else { model.selection.insert(proposal.appID) }
                } label: {
                    Image(systemName: model.selection.contains(proposal.appID) ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.rationale.isEmpty ? proposal.proposalType.rawValue : proposal.rationale)
                        .font(.body)
                    Text(copy.confirmation).font(.footnote).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task { await model.approve(proposal) }
                } label: { Text(copy.actionVerb).bold() }
                .buttonStyle(.borderedProminent)

                Button("Snooze") { model.snooze(proposal) }
                    .buttonStyle(.bordered)
                Button("Dismiss") { model.dismiss(proposal) }
                    .buttonStyle(.bordered)
                Button("Wrong", role: .destructive) { model.markWrong(proposal) }
                    .buttonStyle(.bordered)
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}
