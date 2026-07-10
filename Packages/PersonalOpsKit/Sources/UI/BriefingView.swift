import SwiftUI
import SwiftData
import Core
import Data
import Goals
import Integrations
import DailyLoop

/// # Morning Briefing tab (Phase 3B)
///
/// Renders the deterministically-assembled `MorningBriefing`: attributed real vs agent-owned
/// events, goal tasks due today (with one-tap complete/skip), slipped items, yesterday's
/// captured reality, open loops, and per-source freshness (absent sources shown explicitly).
/// All assembly happens in `BriefingAssembler` (package, unit-tested); this view only fetches
/// inputs and renders the result. After each assembly it writes the glanceable
/// `WidgetSnapshot` for the Home/Lock-Screen widget.
public struct BriefingView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var goals: [Goal]
    @Query private var dailyLogs: [DailyLog]
    @Query private var openLoops: [OpenLoop]

    private let integrations: IntegrationsEnvironment

    @State private var briefing: MorningBriefing?
    @State private var isLoading = false
    /// Surfaced when a one-tap complete/skip write fails, so the tap never silently no-ops
    /// (Rule 6 — degrade *visibly*; REVIEW_REPORT Minor-1).
    @State private var actionError: String?

    public init(integrations: IntegrationsEnvironment) {
        self.integrations = integrations
    }

    private var activeGoals: [Goal] {
        goals.filter { $0.supersededAt == nil && $0.expiresAt == nil && $0.status == .active }
    }

    public var body: some View {
        List {
            if let briefing {
                sourceSection(briefing)
                if let top = briefing.topPriority {
                    Section("Today's #1 priority") {
                        taskRow(top)
                    }
                }
                eventsSection(briefing)
                dueSection(briefing)
                slippedSection(briefing)
                yesterdaySection(briefing)
                openLoopsSection(briefing)
            } else {
                ContentUnavailableView(
                    "Assembling your briefing…", systemImage: "sun.max",
                    description: Text("Pulling today's calendar, goals, and what slipped."))
            }
        }
        .navigationTitle("Briefing")
        .task { await reload() }
        .refreshable { await reload() }
        .alert("Couldn't update that",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sourceSection(_ b: MorningBriefing) -> some View {
        Section("Sources") {
            ForEach(b.sources) { s in
                HStack {
                    Text(sourceName(s.source))
                    Spacer()
                    Text(freshnessLabel(s))
                        .font(.caption)
                        .foregroundStyle(s.isAbsent ? Color.orange : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func eventsSection(_ b: MorningBriefing) -> some View {
        if !b.realEvents.isEmpty || !b.agentEvents.isEmpty {
            Section("Today's calendar") {
                ForEach(b.realEvents) { eventRow($0, tag: "Your calendar") }
                ForEach(b.agentEvents) { eventRow($0, tag: "Agent") }
            }
        }
    }

    @ViewBuilder
    private func dueSection(_ b: MorningBriefing) -> some View {
        if !b.dueTasks.isEmpty {
            Section("Due today") { ForEach(b.dueTasks) { taskRow($0) } }
        }
    }

    @ViewBuilder
    private func slippedSection(_ b: MorningBriefing) -> some View {
        if !b.slippedItems.isEmpty {
            Section("Slipping") { ForEach(b.slippedItems) { taskRow($0) } }
        }
    }

    @ViewBuilder
    private func yesterdaySection(_ b: MorningBriefing) -> some View {
        if let y = b.yesterday {
            Section("Yesterday") { Text(y.summary.isEmpty ? "No note captured." : y.summary) }
        }
    }

    @ViewBuilder
    private func openLoopsSection(_ b: MorningBriefing) -> some View {
        if !b.openLoops.isEmpty {
            Section("Open loops") {
                ForEach(b.openLoops) { loop in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loop.title).font(.callout)
                        if !loop.detail.isEmpty {
                            Text(loop.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func eventRow(_ e: BriefingEvent, tag: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(e.title).font(.callout)
                Spacer()
                Text(tag).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(e.isAgentOwned ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text(e.start.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func taskRow(_ t: BriefingTask) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.callout)
                Text(t.goalTitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                action(on: t, complete: true)
            } label: { Image(systemName: "checkmark.circle") }
                .buttonStyle(.borderless)
            Button {
                action(on: t, complete: false)
            } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .tint(.secondary)
        }
    }

    // MARK: Actions

    /// One-tap complete/skip from the briefing. Writes `GoalProgress` (and, for complete, flips
    /// the task) then re-assembles so the change is immediately reflected.
    private func action(on task: BriefingTask, complete: Bool) {
        guard let goal = activeGoals.first(where: { $0.appID == task.goalID }),
              let model = (goal.tasks ?? []).first(where: { $0.appID == task.taskID })
        else { return }
        let metricKey = PlaybookLibrary.playbook(forKey: goal.playbookKey)?
            .progressSignals.first?.metricKey ?? "progress"
        let actioner = TaskActioner(store: MemoryStore(context: modelContext))
        do {
            if complete {
                try actioner.complete(task: model, goal: goal, metricKey: metricKey, now: Date())
            } else {
                try actioner.skip(task: model, goal: goal, metricKey: metricKey, now: Date())
            }
        } catch let error as AppError {
            actionError = error.userMessage
            return
        } catch {
            actionError = "Couldn't save that update. Nothing was changed — please try again."
            return
        }
        Task { await reload() }
    }

    // MARK: Assembly

    @MainActor
    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = dayStart.addingTimeInterval(86_400)

        let (events, calFresh) = await fetchCalendar(from: dayStart, to: dayEnd, now: now)
        let gmailFresh = integrations.status.status(for: .gmail)?.freshness
            ?? SourceFreshness(source: .gmail, lastSuccessfulSync: nil, stalenessThreshold: 15 * 60)
        // HealthKit is wired in Phase 3C; until then it is honestly marked absent.
        let healthFresh = SourceFreshness(
            source: .healthKit, lastSuccessfulSync: nil, stalenessThreshold: 15 * 60,
            permissionWithheld: true)

        let yesterdayLog = mostRecentLog(before: dayStart)
        let loops = openLoops.filter {
            $0.supersededAt == nil && $0.expiresAt == nil && !$0.isResolved
        }

        let assembled = BriefingAssembler().assemble(
            now: now, calendar: cal,
            calendarEvents: events, calendarFreshness: calFresh,
            gmailFreshness: gmailFresh, healthFreshness: healthFresh,
            goals: activeGoals.map { BriefingGoalInput(goal: $0) },
            yesterday: yesterdayLog, openLoops: loops)

        self.briefing = assembled
        WidgetSnapshotStore().write(WidgetSnapshot.from(assembled))
    }

    /// Fetch today's events across the user's calendars, or an absent marker if unavailable.
    private func fetchCalendar(
        from: Date, to: Date, now: Date
    ) async -> ([CalendarEventDTO], SourceFreshness) {
        guard let api = integrations.calendar else {
            return ([], SourceFreshness(source: .calendar, lastSuccessfulSync: nil,
                                        stalenessThreshold: 15 * 60))
        }
        do {
            let calendars = try await api.listCalendars()
            var all: [CalendarEventDTO] = []
            for c in calendars {
                let events = try await api.listEvents(calendarID: c.id, from: from, to: to)
                all.append(contentsOf: events)
            }
            let fresh = integrations.status.status(for: .calendar)?.freshness
                ?? SourceFreshness(source: .calendar, lastSuccessfulSync: now,
                                   stalenessThreshold: 15 * 60)
            return (all, fresh)
        } catch {
            let fresh = integrations.status.status(for: .calendar)?.freshness
                ?? SourceFreshness(source: .calendar, lastSuccessfulSync: nil,
                                   stalenessThreshold: 15 * 60)
            return ([], fresh)
        }
    }

    private func mostRecentLog(before dayStart: Date) -> DailyLog? {
        dailyLogs
            .filter { $0.supersededAt == nil && $0.expiresAt == nil && $0.logDate < dayStart }
            .max { $0.logDate < $1.logDate }
    }

    // MARK: Labels

    private func sourceName(_ s: DataSource) -> String {
        switch s {
        case .calendar: return "Calendar"
        case .gmail: return "Gmail"
        case .healthKit: return "HealthKit"
        case .reasoning: return "Reasoning"
        case .iMessage: return "iMessage"
        }
    }

    private func freshnessLabel(_ s: SourceFreshnessSnapshot) -> String {
        switch s.availability {
        case .fresh:
            if let age = s.ageSeconds { return "synced \(Self.ago(age))" }
            return "synced"
        case .stale:
            if let age = s.ageSeconds { return "stale — \(Self.ago(age))" }
            return "stale"
        case .unavailable: return "not connected"
        case .permissionWithheld: return "turned off"
        }
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h ago"
    }
}
