import Foundation
import Core
import Data

/// # GoalPlanMaterializer — turn a generated plan into persisted memory
///
/// Bridges the pure planning layer (`GeneratedPlan`, value types) to the persistence layer
/// (`Goal` + `GoalTask` SwiftData models via `MemoryStore`). The `Goal` is inserted as a
/// memory fact (revision 1, with a `factKey`); its `GoalTask`s are structural children
/// created from the plan's `PlannedTask`s, carrying their flexibility/priority/time-window/
/// duration/conflict-policy metadata unchanged.
///
/// This performs **no calendar I/O** — it writes only to the local store. Calendar events
/// come later, and only via approved Phase 4A Proposals.
public struct GoalPlanMaterializer {

    private let store: MemoryStore

    /// Construct on the `MemoryStore`'s owning actor (`MemoryStore` is not `Sendable`).
    public init(store: MemoryStore) {
        self.store = store
    }

    /// Persist `plan` as a new active `Goal` (revision 1) with its tasks. Returns the goal.
    ///
    /// - Parameters:
    ///   - plan: the generated plan to persist.
    ///   - source: provenance for the goal fact (defaults to `.user` — the user created it).
    ///   - factKey: semantic identity; defaults to a slug of the title under `goal:`.
    @discardableResult
    public func persist(
        _ plan: GeneratedPlan,
        source: MemorySource = .user,
        factKey: String? = nil,
        now: Date
    ) throws -> Goal {
        let goal = Goal(
            source: source,
            createdAt: now,
            updatedAt: now,
            title: plan.goalTitle,
            playbookKey: plan.playbookKey,
            status: .active,
            targetDate: plan.targetDate)
        goal.factKey = factKey ?? "goal:\(Self.slug(plan.goalTitle))"

        goal.tasks = plan.tasks.map { planned in
            GoalTask(
                createdAt: now,
                updatedAt: now,
                title: planned.title,
                flexibility: planned.flexibility,
                priority: planned.priority,
                earliestAcceptable: planned.earliestAcceptable,
                latestAcceptable: planned.latestAcceptable,
                expectedDuration: planned.expectedDuration,
                conflictPolicy: planned.conflictPolicy,
                isComplete: false)
        }

        try store.insert(goal)
        return goal
    }

    /// Lowercase, `_`-joined slug for a stable-ish `factKey`. Single-user scale; collisions
    /// are acceptable (they simply read as revisions/conflicts of the same-named goal).
    static func slug(_ title: String) -> String {
        let allowed = title.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : " "
        }
        return String(allowed)
            .split(separator: " ")
            .joined(separator: "_")
    }
}
