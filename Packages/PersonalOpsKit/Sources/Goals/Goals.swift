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
/// Phase 0 fixes the vocabulary so later phases share one contract.
public enum TaskFlexibility: String, Equatable, Sendable, Codable {
    case fixed, movable, optional
}

public enum ConflictPolicy: String, Equatable, Sendable, Codable {
    case block, warn, allow
}

public enum GoalsModule {
    public static let supportedPlaybooks = ["training", "job_search"]
}
