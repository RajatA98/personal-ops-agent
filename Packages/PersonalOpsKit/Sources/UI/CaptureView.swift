import SwiftUI
import SwiftData
import Core
import Data
import Goals
import DailyLoop

/// # Evening Capture tab (Phase 3B)
///
/// A fast text/tap flow (voice arrives in Phase 6): tick off what you did, skip what you
/// didn't, add a quick note, and save. Writing goes through `EveningCapture` (package,
/// unit-tested), which updates `DailyLog` / `GoalProgress` / `OpenLoop` via the append-only
/// `MemoryStore`. No form fields required for the common one-tap case.
public struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var goals: [Goal]

    @State private var note: String = ""
    @State private var openLoopTitle: String = ""
    @State private var selection: [UUID: Outcome] = [:]  // taskID → chosen outcome
    @State private var confirmation: String?

    public init() {}

    private enum Outcome { case completed, skipped }

    private var activeGoals: [Goal] {
        goals.filter { $0.supersededAt == nil && $0.expiresAt == nil && $0.status == .active }
    }

    /// Incomplete tasks across active goals (what capture can act on).
    private var openTasks: [(goal: Goal, task: GoalTask)] {
        activeGoals.flatMap { goal in
            (goal.tasks ?? [])
                .filter { !$0.isComplete }
                .sorted { ($0.earliestAcceptable ?? .distantFuture) < ($1.earliestAcceptable ?? .distantFuture) }
                .prefix(12)
                .map { (goal, $0) }
        }
    }

    public var body: some View {
        Form {
            if let confirmation {
                Section { Label(confirmation, systemImage: "checkmark.seal").foregroundStyle(.green) }
            }

            Section("What happened with today's tasks?") {
                if openTasks.isEmpty {
                    Text("Nothing outstanding — you're all caught up.")
                        .foregroundStyle(.secondary)
                }
                ForEach(openTasks, id: \.task.appID) { pair in
                    taskRow(goal: pair.goal, task: pair.task)
                }
            }

            Section("Quick note") {
                TextField("How did the day go?", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section("Remember an open loop (optional)") {
                TextField("e.g. waiting to hear back from the recruiter", text: $openLoopTitle)
            }

            Section {
                Button("Save capture") { save() }
                    .disabled(!hasSomethingToSave)
            } footer: {
                Text("Updates your daily log, goal progress, and open loops. Nothing is sent anywhere.")
            }
        }
        .navigationTitle("Evening Capture")
    }

    private func taskRow(goal: Goal, task: GoalTask) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.callout)
                Text(goal.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: binding(for: task.appID)) {
                Image(systemName: "circle").tag(Optional<Outcome>.none)
                Image(systemName: "checkmark").tag(Optional(Outcome.completed))
                Image(systemName: "xmark").tag(Optional(Outcome.skipped))
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
    }

    private func binding(for id: UUID) -> Binding<Outcome?> {
        Binding(get: { selection[id] }, set: { selection[id] = $0 })
    }

    private var hasSomethingToSave: Bool {
        !selection.isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !openLoopTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let now = Date()
        var completed: [TaskOutcome] = []
        var skipped: [TaskOutcome] = []

        for (goal, task) in openTasks {
            guard let outcome = selection[task.appID] else { continue }
            let metricKey = PlaybookLibrary.playbook(forKey: goal.playbookKey)?
                .progressSignals.first?.metricKey ?? "progress"
            let action = TaskOutcome(task: task, goal: goal, metricKey: metricKey)
            switch outcome {
            case .completed: completed.append(action)
            case .skipped: skipped.append(action)
            }
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLoop = openLoopTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = CaptureInput(
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            completed: completed,
            skipped: skipped,
            openLoops: trimmedLoop.isEmpty ? [] : [OpenLoopDraft(title: trimmedLoop)])

        let capture = EveningCapture(store: MemoryStore(context: modelContext))
        guard let result = try? capture.apply(input, now: now) else { return }

        confirmation = "Captured: \(result.completedCount) done, \(result.skippedCount) skipped."
        note = ""; openLoopTitle = ""; selection = [:]
    }
}
