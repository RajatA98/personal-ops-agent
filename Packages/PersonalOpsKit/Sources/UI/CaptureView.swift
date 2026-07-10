import SwiftUI
import SwiftData
import Core
import Data
import Goals
import DailyLoop
import Voice

/// # Evening Capture tab (Phase 3B; voice-first path Phase 6)
///
/// A fast flow: tick off what you did, skip what you didn't, add a quick note — or tap the mic
/// and just say it ("done with the pool swim, skipped strength, felt tired"). The spoken path
/// parses the sentence deterministically into a `CaptureInput`, shows a one-step review, and
/// applies it on confirmation. Writing goes through `EveningCapture` (package, unit-tested),
/// which updates `DailyLog` / `GoalProgress` / `OpenLoop` via the append-only `MemoryStore`.
/// Nothing persists before you confirm; the raw transcript is never stored.
public struct CaptureView: View {
    private let voice: VoiceEnvironment?

    @Environment(\.modelContext) private var modelContext
    @Query private var goals: [Goal]

    @State private var note: String = ""
    @State private var openLoopTitle: String = ""
    @State private var selection: [UUID: Outcome] = [:]  // taskID → chosen outcome
    @State private var confirmation: String?
    @State private var voiceController: VoiceCaptureController?

    public init(voice: VoiceEnvironment? = nil) {
        self.voice = voice
    }

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

            if voice != nil { voiceSection }

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

    @ViewBuilder private var voiceSection: some View {
        Section("Capture by voice") {
            switch voiceController?.state ?? .idle {
            case .idle, .applied, .error:
                Button {
                    startVoiceCapture()
                } label: {
                    Label("Speak your capture", systemImage: "mic.circle.fill")
                }
            case .listening:
                Label("Listening…", systemImage: "waveform").foregroundStyle(.secondary)
            case .transcribing:
                Label("Transcribing…", systemImage: "text.bubble").foregroundStyle(.secondary)
            case let .reviewing(summary, lowConfidence):
                VStack(alignment: .leading, spacing: 8) {
                    if lowConfidence {
                        Label("That wasn't very clear — please check before saving.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(summary).font(.callout)
                    HStack {
                        Button("Save") { applyVoiceCapture() }
                            .buttonStyle(.borderedProminent)
                        Button("Discard", role: .cancel) { voiceController?.cancel() }
                    }
                }
            }
            if case let .error(message) = voiceController?.state {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func openTaskPairs() -> [(goal: Goal, task: GoalTask)] {
        openTasks.map { (goal: $0.goal, task: $0.task) }
    }

    private func startVoiceCapture() {
        guard let voice else { return }
        let controller = voiceController
            ?? voice.captureController(store: MemoryStore(context: modelContext))
        voiceController = controller
        let pairs = openTaskPairs()
        Task { await controller.captureTurn(openTasks: pairs) }
    }

    private func applyVoiceCapture() {
        guard let result = voiceController?.confirm() else { return }
        confirmation = "Captured: \(result.completedCount) done, \(result.skippedCount) skipped."
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
