import Foundation
import Core

/// A single proposed calendar block in a preview. **Purely descriptive** — it names what an
/// agent-owned calendar event *would* look like if the user later approves it. It is not an
/// event, and building one performs no calendar I/O.
public struct ProposedBlock: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let start: Date
    public let end: Date
    public let flexibility: TaskFlexibility
    public let conflictPolicy: ConflictPolicy
    public let priority: Int
    /// The rule that generated the underlying task, for grouping/inspection.
    public let ruleKey: String

    public init(
        id: UUID = UUID(),
        title: String,
        start: Date,
        end: Date,
        flexibility: TaskFlexibility,
        conflictPolicy: ConflictPolicy,
        priority: Int,
        ruleKey: String
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.flexibility = flexibility
        self.conflictPolicy = conflictPolicy
        self.priority = priority
        self.ruleKey = ruleKey
    }
}

/// # SchedulePreview — inspectable, never executed
///
/// The Phase 3A deliverable: a goal plan rendered as a set of proposed calendar blocks the
/// user can inspect *before* anything is written. It is a pure value type and **holds no
/// reference to any calendar API**. Turning these blocks into real agent-owned calendar
/// events is Phase 4A's job, gated behind explicit approval in the Ops Inbox (Safety Rule
/// #1/#2). Nothing in this module can call the calendar — the `Goals` target does not even
/// depend on `Integrations` — so "the preview writes to no calendar" is guaranteed by
/// construction, not merely by convention.
public struct SchedulePreview: Sendable, Equatable {
    public let goalTitle: String
    public let playbookKey: String
    /// The window this preview covers.
    public let window: DateInterval
    public let blocks: [ProposedBlock]

    public init(goalTitle: String, playbookKey: String, window: DateInterval, blocks: [ProposedBlock]) {
        self.goalTitle = goalTitle
        self.playbookKey = playbookKey
        self.window = window
        self.blocks = blocks
    }

    public var isEmpty: Bool { blocks.isEmpty }
}

/// Builds a `SchedulePreview` from a `GeneratedPlan`. No side effects, no calendar access.
public struct SchedulePreviewBuilder: Sendable {
    public init() {}

    /// Preview every task whose start falls within `window`, sorted chronologically. Defaults
    /// to the first seven days from the plan's start — a realistic "here's your week" preview.
    public func preview(for plan: GeneratedPlan, window: DateInterval? = nil) -> SchedulePreview {
        let effectiveWindow = window ?? DateInterval(
            start: plan.startDate,
            end: plan.startDate.addingTimeInterval(7 * 86_400))

        let blocks = plan.tasks
            .filter { effectiveWindow.contains($0.scheduledStart) }
            .sorted { $0.scheduledStart < $1.scheduledStart }
            .map { task in
                ProposedBlock(
                    title: task.title,
                    start: task.scheduledStart,
                    end: task.scheduledStart.addingTimeInterval(task.expectedDuration),
                    flexibility: task.flexibility,
                    conflictPolicy: task.conflictPolicy,
                    priority: task.priority,
                    ruleKey: task.ruleKey)
            }

        return SchedulePreview(
            goalTitle: plan.goalTitle,
            playbookKey: plan.playbookKey,
            window: effectiveWindow,
            blocks: blocks)
    }
}
