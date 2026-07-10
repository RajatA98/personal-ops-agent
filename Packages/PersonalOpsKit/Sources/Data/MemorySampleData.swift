import Foundation
import SwiftData
import Core

/// Seeds a store with a small, illustrative set of memory facts so the app shell has
/// something real to render (Phase 1 acceptance: "the memory system is visible with
/// seed/fixture data"). Deliberately exercises the three lifecycle behaviors so they're
/// visible in the UI, not just in tests:
///   • a **corrected** preference (revision chain: superseded revision 1 + active 2),
///   • an **expired** open loop (present in history, absent from the default view),
///   • a **conflict** (two active decisions for the same `factKey`).
///
/// Idempotent: does nothing if any `Preference` already exists.
public enum MemorySampleData {

    @discardableResult
    public static func seedIfEmpty(
        context: ModelContext,
        clock: any Clock = SystemClock()
    ) throws -> Bool {
        let existing = try context.fetch(FetchDescriptor<Preference>())
        guard existing.isEmpty else { return false }
        try seed(context: context, clock: clock)
        return true
    }

    public static func seed(context: ModelContext, clock: any Clock) throws {
        let now = clock.now
        let store = MemoryStore(context: context, clock: clock)
        let day: TimeInterval = 86_400

        // 1) A preference that gets corrected — demonstrates the revision chain.
        let workoutPref = Preference(
            source: .user, createdAt: now.addingTimeInterval(-30 * day),
            updatedAt: now.addingTimeInterval(-30 * day),
            key: "workout_time_of_day", value: "evening"
        )
        workoutPref.factKey = "preference:workout_time_of_day"
        try store.insert(workoutPref)
        try store.correct(workoutPref, reason: "User said they switched to mornings", asOf: now.addingTimeInterval(-2 * day)) {
            $0.value = "morning"
        }

        // 2) An expired open loop — drops out of the default view, stays in history.
        let staleLoop = OpenLoop(
            source: .gmail, createdAt: now.addingTimeInterval(-20 * day),
            updatedAt: now.addingTimeInterval(-20 * day),
            expiresAt: now.addingTimeInterval(-1 * day),
            title: "Awaiting reply from Contoso recruiter", detail: "Sent follow-up; no response."
        )
        staleLoop.factKey = "open_loop:contoso_recruiter"
        try store.insert(staleLoop)

        // An active open loop, for contrast.
        let liveLoop = OpenLoop(
            source: .user, createdAt: now.addingTimeInterval(-3 * day),
            updatedAt: now.addingTimeInterval(-3 * day),
            title: "Book pool lane for brick workout", detail: "Need a lane Sat morning."
        )
        liveLoop.factKey = "open_loop:pool_lane"
        try store.insert(liveLoop)

        // 3) A conflict — two active decisions for the same fact, no supersession.
        let decisionA = Decision(
            source: .user, createdAt: now.addingTimeInterval(-5 * day),
            updatedAt: now.addingTimeInterval(-5 * day),
            topic: "acme_offer", choice: "accept", rationale: "Better comp."
        )
        decisionA.factKey = "decision:acme_offer"
        let decisionB = Decision(
            source: .gmail, confidence: 0.6, createdAt: now.addingTimeInterval(-4 * day),
            updatedAt: now.addingTimeInterval(-4 * day),
            topic: "acme_offer", choice: "decline", rationale: "Email suggests you passed."
        )
        decisionB.factKey = "decision:acme_offer"
        try store.insert(decisionA)
        try store.insert(decisionB)

        // A goal with a task and a progress signal (relationship shapes, for the UI).
        let goal = Goal(
            source: .user, createdAt: now.addingTimeInterval(-40 * day),
            updatedAt: now, title: "Ironman 70.3 in October",
            playbookKey: "training", status: .active,
            targetDate: now.addingTimeInterval(90 * day)
        )
        goal.factKey = "goal:ironman_70_3"
        let task = GoalTask(
            title: "Saturday long ride", flexibility: .fixed, priority: 1,
            expectedDuration: 3 * 3600, conflictPolicy: .block
        )
        let progress = GoalProgress(
            source: .user, createdAt: now.addingTimeInterval(-1 * day), updatedAt: now.addingTimeInterval(-1 * day),
            metricKey: "weekly_long_ride_km", value: 65, note: "Felt strong."
        )
        goal.tasks = [task]
        goal.progress = [progress]
        progress.factKey = "goal_progress:ironman_70_3:weekly_long_ride_km"
        try store.insert(goal)

        // A commitment, a pattern, a daily log, and a pending proposal.
        let commitment = Commitment(
            source: .user, title: "Submit expense report",
            dueDate: now.addingTimeInterval(2 * day)
        )
        commitment.factKey = "commitment:expense_report"
        try store.insert(commitment)

        let pattern = Pattern(
            source: .inference, confidence: 0.7,
            name: "Skips morning workouts after late nights",
            detail: "3 of last 4 late nights → missed AM session.", occurrences: 3
        )
        pattern.factKey = "pattern:late_night_skip"
        try store.insert(pattern)

        let log = DailyLog(
            source: .user, logDate: now.addingTimeInterval(-1 * day),
            summary: "Swim 2km, recruiter call, shipped Phase 0."
        )
        log.factKey = "daily_log:\(Self.dayKey(now.addingTimeInterval(-1 * day)))"
        try store.insert(log)

        let proposal = Proposal(
            source: .gmail, confidence: 0.8,
            expiresAt: now.addingTimeInterval(3 * day),
            type: .createAgentCalendarEvent, status: .pending,
            rationale: "Email mentions a 3pm Thursday interview — add to the agent calendar?",
            payload: #"{"title":"Contoso interview","start":"2026-07-16T15:00:00Z"}"#
        )
        proposal.factKey = "proposal:contoso_interview"
        try store.insert(proposal)
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
