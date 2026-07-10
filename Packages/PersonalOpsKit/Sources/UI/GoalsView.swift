import SwiftUI
import SwiftData
import Core
import Data
import Goals
import Integrations
import Proposals

/// # Goals tab (Phase 3A UI)
///
/// A functional (not polished) surface over the goal engine: list active goals, create one
/// from a playbook via an intake flow, and inspect the generated plan and its schedule
/// **preview**. The preview itself writes nothing to a calendar; a **"Propose schedule"** action
/// routes the plan through `PlanProposalCoordinator` so it lands as *pending* proposals in the Ops
/// Inbox (real calendar events still only arrive via an approved Phase 4A Proposal).
public struct GoalsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var goals: [Goal]
    @State private var showingCreate = false

    private let integrations: IntegrationsEnvironment

    public init(integrations: IntegrationsEnvironment) {
        self.integrations = integrations
    }

    /// Active (non-superseded, non-expired) goals only.
    private var activeGoals: [Goal] {
        goals.filter { $0.supersededAt == nil && $0.expiresAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public var body: some View {
        List {
            if activeGoals.isEmpty {
                ContentUnavailableView(
                    "No goals yet",
                    systemImage: "target",
                    description: Text("Create a goal from a playbook to generate a plan and a schedule preview."))
            }
            ForEach(activeGoals, id: \.appID) { goal in
                NavigationLink {
                    GoalDetailView(goal: goal, activeGoals: activeGoals, integrations: integrations)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(goal.title).font(.headline)
                        Text(playbookName(goal.playbookKey))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(goal.tasks?.count ?? 0) planned tasks · \(goal.status.rawValue)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("Create goal", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                CreateGoalView()
            }
        }
    }

    private func playbookName(_ key: String) -> String {
        PlaybookLibrary.playbook(forKey: key)?.displayName ?? key
    }
}

// MARK: - Goal detail (plan + schedule preview)

struct GoalDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let goal: Goal
    /// All active goals, so "Propose schedule" can run cross-goal conflict detection.
    let activeGoals: [Goal]
    let integrations: IntegrationsEnvironment

    @State private var proposing = false
    @State private var proposeSummary: String?
    @State private var proposeError: String?

    private var playbook: GoalPlaybook? { PlaybookLibrary.playbook(forKey: goal.playbookKey) }

    /// Rebuild a preview for the next 7 days from the goal's persisted tasks, purely for
    /// display. (No calendar access.)
    private var previewBlocks: [ProposedBlock] {
        let now = Date()
        let window = DateInterval(start: now, end: now.addingTimeInterval(7 * 86_400))
        return (goal.tasks ?? [])
            .compactMap { task -> ProposedBlock? in
                guard let start = task.earliestAcceptable, window.contains(start) else { return nil }
                return ProposedBlock(
                    title: task.title,
                    start: start,
                    end: start.addingTimeInterval(task.expectedDuration),
                    flexibility: task.flexibility,
                    conflictPolicy: task.conflictPolicy,
                    priority: task.priority,
                    ruleKey: task.title)
            }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        List {
            Section("Goal") {
                LabeledContent("Playbook", value: playbook?.displayName ?? goal.playbookKey)
                LabeledContent("Status", value: goal.status.rawValue)
                if let target = goal.targetDate {
                    LabeledContent("Target", value: target.formatted(date: .abbreviated, time: .omitted))
                }
                LabeledContent("Planned tasks", value: "\(goal.tasks?.count ?? 0)")
            }

            if let playbook {
                // Phase 3C: HealthKit pacing toggle + visible "HealthKit-influenced" label.
                PacingInsightView(playbook: playbook)

                Section("Milestones") {
                    ForEach(playbook.milestoneTemplates, id: \.key) { m in
                        Text(m.title).font(.callout)
                    }
                }
                Section("Tracks") {
                    ForEach(playbook.progressSignals, id: \.metricKey) { s in
                        LabeledContent(s.label, value: s.unit)
                    }
                }
            }

            Section("Schedule preview (next 7 days) — inspect only, not written to calendar") {
                if previewBlocks.isEmpty {
                    Text("No blocks in the next 7 days.").foregroundStyle(.secondary)
                }
                ForEach(previewBlocks) { block in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.title).font(.callout)
                        Text(block.start.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(block.flexibility.rawValue) · \(block.conflictPolicy.rawValue)")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let pacing = block.pacing {
                            Label(pacing.label, systemImage: "heart.text.square.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.pink)
                        }
                    }
                }
            }

            proposeSection
        }
        .navigationTitle(goal.title)
        .navigationBarTitleDisplayModeInlineIfAvailable()
    }

    /// # "Propose schedule" — route this goal's plan into the Ops Inbox (Phase 4A wiring)
    ///
    /// Builds pending create-event proposals for this goal's scheduled tasks and, at the same
    /// seam, runs cross-goal conflict detection across all active goals so collisions surface as
    /// their own proposals. Nothing is written to any calendar here — every item lands `.pending`
    /// for review in the Ops Inbox (Safety Rule #1).
    @ViewBuilder
    private var proposeSection: some View {
        Section {
            Button {
                propose()
            } label: {
                HStack {
                    Label("Propose schedule to Ops Inbox", systemImage: "tray.and.arrow.down")
                    if proposing { Spacer(); ProgressView() }
                }
            }
            .disabled(proposing)
            if let proposeSummary {
                Text(proposeSummary).font(.caption).foregroundStyle(.secondary)
            }
            if let proposeError {
                Label(proposeError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } footer: {
            Text("Adds these blocks to your Ops Inbox as proposals to review. Any cross-goal conflicts are surfaced there too. Nothing is written to a calendar until you approve it.")
        }
    }

    private func propose() {
        proposing = true
        proposeError = nil
        proposeSummary = nil
        defer { proposing = false }
        let coordinator = PlanProposalCoordinator(context: modelContext, calendar: integrations.calendar)
        do {
            let summary = try coordinator.proposeSchedule(for: goal, amongActiveGoals: activeGoals)
            if summary.total == 0 {
                proposeSummary = "Nothing new to propose — these blocks are already in your Ops Inbox."
            } else {
                var parts = ["\(summary.scheduled) schedule proposal(s)"]
                if summary.conflicts > 0 { parts.append("\(summary.conflicts) conflict(s) to resolve") }
                proposeSummary = "Added " + parts.joined(separator: " and ") + " to your Ops Inbox."
            }
        } catch let error as AppError {
            proposeError = error.userMessage
        } catch {
            proposeError = "Couldn't create proposals right now. Please try again."
        }
    }
}

// MARK: - Create goal (intake → plan → preview → save)

struct CreateGoalView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var playbook: GoalPlaybook = PlaybookLibrary.all[0]
    @State private var title: String = ""
    @State private var targetDate: Date = Date().addingTimeInterval(8 * 7 * 86_400)
    @State private var choiceAnswers: [String: String] = [:]
    @State private var numberAnswers: [String: Double] = [:]
    @State private var textAnswers: [String: String] = [:]

    var body: some View {
        Form {
            Section("Playbook") {
                Picker("Type", selection: playbookBinding) {
                    ForEach(PlaybookLibrary.all, id: \.key) { pb in
                        Text(pb.displayName).tag(pb.key)
                    }
                }
                TextField("Goal title", text: $title)
            }

            Section("Intake") {
                ForEach(playbook.intakeQuestions) { q in
                    intakeRow(q)
                }
            }

            Section {
                Button("Generate plan & save") { save() }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Generates a deterministic plan and schedule preview. Saves the goal and its tasks locally — no calendar events are created.")
            }
        }
        .navigationTitle("New goal")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private var playbookBinding: Binding<String> {
        Binding(
            get: { playbook.key },
            set: { newKey in
                if let pb = PlaybookLibrary.playbook(forKey: newKey) { playbook = pb }
            })
    }

    @ViewBuilder
    private func intakeRow(_ q: IntakeQuestion) -> some View {
        switch q.kind {
        case .date:
            DatePicker(q.prompt, selection: $targetDate, displayedComponents: .date)
        case .choice:
            Picker(q.prompt, selection: choiceBinding(q.id, default: q.choices.first ?? "")) {
                ForEach(q.choices, id: \.self) { Text($0).tag($0) }
            }
        case .number:
            HStack {
                Text(q.prompt)
                Spacer()
                TextField(q.unit ?? "", value: numberBinding(q.id), format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
        case .text:
            TextField(q.prompt, text: textBinding(q.id))
        }
    }

    private func choiceBinding(_ id: String, default def: String) -> Binding<String> {
        Binding(get: { choiceAnswers[id] ?? def }, set: { choiceAnswers[id] = $0 })
    }
    private func numberBinding(_ id: String) -> Binding<Double> {
        Binding(get: { numberAnswers[id] ?? 0 }, set: { numberAnswers[id] = $0 })
    }
    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { textAnswers[id] ?? "" }, set: { textAnswers[id] = $0 })
    }

    private func save() {
        var answers = IntakeAnswers()
        for q in playbook.intakeQuestions {
            switch q.kind {
            case .date:   answers.set(q.id, .date(targetDate))
            case .choice: if let v = choiceAnswers[q.id] { answers.set(q.id, .choice(v)) }
            case .number: if let v = numberAnswers[q.id] { answers.set(q.id, .number(v)) }
            case .text:   if let v = textAnswers[q.id] { answers.set(q.id, .text(v)) }
            }
        }

        let now = Date()
        let plan = GoalPlanner().generatePlan(
            playbook: playbook,
            answers: answers,
            goalTitle: title,
            now: now,
            targetDate: targetDate)

        let store = MemoryStore(context: modelContext)
        _ = try? GoalPlanMaterializer(store: store).persist(plan, now: now)
        dismiss()
    }
}

// Small cross-platform helper: inline title only where the modifier exists (iOS).
private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeInlineIfAvailable() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
