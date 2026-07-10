import SwiftUI
import SwiftData
import Core
import Data

/// Browses the memory store, one section per typed entity. For each *fact* (grouped by
/// `factKey`) it shows the current lifecycle state — a single active revision, a conflict
/// (two active claims), or retired (all revisions superseded/expired) — and drills into the
/// full append-only revision history. This is the Phase 1 "memory system is visible on seed
/// data" surface, not polished product UI.
struct MemoryBrowserView: View {
    @Query(sort: \Preference.factKey) private var preferences: [Preference]
    @Query(sort: \Decision.factKey) private var decisions: [Decision]
    @Query(sort: \OpenLoop.factKey) private var openLoops: [OpenLoop]
    @Query(sort: \Commitment.factKey) private var commitments: [Commitment]
    @Query(sort: \Goal.factKey) private var goals: [Goal]
    @Query(sort: \GoalProgress.factKey) private var goalProgress: [GoalProgress]
    @Query(sort: \DailyLog.factKey) private var dailyLogs: [DailyLog]
    @Query(sort: \Proposal.factKey) private var proposals: [Proposal]

    var body: some View {
        List {
            Section {
                Text("Every correction adds a revision; the prior one is kept, marked superseded. Default views show the active, non-expired revision — and surface conflicts instead of guessing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Append-only memory")
            }

            MemoryFactSection(title: "Preferences", items: preferences)
            MemoryFactSection(title: "Decisions", items: decisions)
            MemoryFactSection(title: "Open Loops", items: openLoops)
            MemoryFactSection(title: "Commitments", items: commitments)
            MemoryFactSection(title: "Goals", items: goals)
            MemoryFactSection(title: "Goal Progress", items: goalProgress)
            MemoryFactSection(title: "Daily Logs", items: dailyLogs)
            MemoryFactSection(title: "Proposals", items: proposals)
        }
        .navigationTitle("Memory")
    }
}

/// One section: groups a type's rows by `factKey` and renders a row per fact.
private struct MemoryFactSection<T: PersistentModel & MemoryEntity>: View {
    let title: String
    let items: [T]

    private var facts: [(key: String, revisions: [T])] {
        Dictionary(grouping: items, by: { $0.factKey })
            .map { (key: $0.key, revisions: $0.value.sorted { $0.revision < $1.revision }) }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        if !facts.isEmpty {
            Section(title) {
                ForEach(facts, id: \.key) { fact in
                    NavigationLink {
                        MemoryHistoryView(factKey: fact.key, revisions: fact.revisions)
                    } label: {
                        MemoryFactRow(factKey: fact.key, revisions: fact.revisions)
                    }
                }
            }
        }
    }
}

/// A single fact row: name + a lifecycle badge derived from its active revisions.
private struct MemoryFactRow<T: MemoryEntity>: View {
    let factKey: String
    let revisions: [T]

    private var active: [T] { revisions.filter { $0.isActive(asOf: .now) } }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(factKey)
                    .font(.subheadline)
                Text("\(revisions.count) revision\(revisions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        switch active.count {
        case 0:
            LifecycleBadge(text: "retired", color: .secondary)
        case 1:
            LifecycleBadge(text: "active", color: .green)
        default:
            LifecycleBadge(text: "conflict", color: .orange)
        }
    }
}

/// The full append-only history for one fact.
private struct MemoryHistoryView<T: MemoryEntity>: View {
    let factKey: String
    let revisions: [T]

    var body: some View {
        List {
            ForEach(revisions, id: \.appID) { revision in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Revision \(revision.revision)").font(.headline)
                        Spacer()
                        stateBadge(revision)
                    }
                    Text("Source: \(revision.source.rawValue)  ·  Confidence: \(revision.confidence, format: .number.precision(.fractionLength(2)))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = revision.correctionReason {
                        Text("Correction: \(reason)").font(.caption)
                    }
                    if let superseded = revision.supersededAt {
                        Text("Superseded \(superseded, format: .dateTime)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let expires = revision.expiresAt {
                        Text("Expires \(expires, format: .dateTime)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle(factKey)
        .navigationBarTitleDisplayModeInlineIfAvailable()
    }

    @ViewBuilder private func stateBadge(_ r: T) -> some View {
        if r.isSuperseded {
            LifecycleBadge(text: "superseded", color: .secondary)
        } else if r.isExpired(asOf: .now) {
            LifecycleBadge(text: "expired", color: .secondary)
        } else {
            LifecycleBadge(text: "active", color: .green)
        }
    }
}

private struct LifecycleBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

private extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` is iOS-only; keep the shared view compiling
    /// for the Phase 7B macOS target by no-op'ing there.
    @ViewBuilder func navigationBarTitleDisplayModeInlineIfAvailable() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
