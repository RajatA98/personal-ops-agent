import Foundation
import Core

/// # Goals module (goal engine & playbooks)
///
/// Phase 3A fills this in: the generalized goal schema, reusable playbooks (Training,
/// Job Search), task-generation rules, slip detection, and schedule-block templates that
/// produce a *proposal preview* (never a direct calendar write). The `GoalTask`
/// flexibility/priority/conflict-policy metadata consumed by Phase 4C's conflict
/// detection is defined here.
///
/// The shared scheduling vocabulary (`TaskFlexibility`, `ConflictPolicy`) lives in `Core`
/// (`Core/Vocabulary.swift`) so the persistence layer can store it without a dependency
/// cycle — Phase 1 relocated it there from this file (a move, not a redefinition).
/// Reference those types via `import Core`.
public enum GoalsModule {
    public static let supportedPlaybooks = ["training", "job_search"]
}
