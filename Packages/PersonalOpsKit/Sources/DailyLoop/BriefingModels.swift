import Foundation
import Core

// MARK: - Structured, serializable briefing value
//
// Everything in this file is a plain `Codable`, `Sendable`, `Equatable` value type. That is
// deliberate: the Morning Briefing is assembled **deterministically in Swift** (Phase 3B), and
// the very same structured value is what Phase 5 hands to the LLM to write a narrative
// (`AGENT_DESIGN` §4). Because the model never fetches its own data for this flow, the
// briefing must be a self-contained, decoupled snapshot — never SwiftData model references.
//
// The two safety-relevant properties the acceptance criteria assert on:
//   • real vs agent-owned calendar events are attributed **separately** (`realEvents` /
//     `agentEvents`, and `BriefingEvent.isAgentOwned`);
//   • every source carries an **explicit availability marker** — a missing Gmail/HealthKit is
//     rendered absent, never silently omitted (`SourceFreshnessSnapshot.isAbsent`).

/// A calendar event as it appears in the briefing, attributed to its origin.
public struct BriefingEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    /// `true` for events on the dedicated agent-owned calendar; `false` for the user's real
    /// calendars. The briefing view and Phase 5 narrative must keep these visually distinct.
    public let isAgentOwned: Bool

    public init(id: String, title: String, start: Date, end: Date, isAgentOwned: Bool) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAgentOwned = isAgentOwned
    }
}

/// A goal task as it appears in the briefing (due-today or slipped). A flat snapshot of the
/// persisted `GoalTask` — no model reference, so it serializes cleanly.
public struct BriefingTask: Codable, Equatable, Sendable, Identifiable {
    /// The persisted `GoalTask.appID` — the handle one-tap complete/skip acts on.
    public let taskID: UUID
    /// The owning `Goal.appID`, so the UI can attribute the task to its goal.
    public let goalID: UUID
    public let goalTitle: String
    public let title: String
    public let flexibility: TaskFlexibility
    public let priority: Int
    public let earliestAcceptable: Date?
    public let latestAcceptable: Date?
    public let isComplete: Bool

    public var id: UUID { taskID }

    public init(taskID: UUID, goalID: UUID, goalTitle: String, title: String,
                flexibility: TaskFlexibility, priority: Int,
                earliestAcceptable: Date?, latestAcceptable: Date?, isComplete: Bool) {
        self.taskID = taskID
        self.goalID = goalID
        self.goalTitle = goalTitle
        self.title = title
        self.flexibility = flexibility
        self.priority = priority
        self.earliestAcceptable = earliestAcceptable
        self.latestAcceptable = latestAcceptable
        self.isComplete = isComplete
    }
}

/// Yesterday's captured reality, as recorded by a prior Evening Capture.
public struct BriefingDailyLog: Codable, Equatable, Sendable {
    public let date: Date
    public let summary: String
    public init(date: Date, summary: String) {
        self.date = date
        self.summary = summary
    }
}

/// An unresolved thread of attention carried into today.
public struct BriefingOpenLoop: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let detail: String
    public init(id: UUID, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// A serializable snapshot of one source's freshness at briefing time. This is the honest
/// "degrade visibly, never silently" marker (Safety Rule #6): a source the briefing could not
/// read is present here marked `.unavailable`/`.permissionWithheld` (`isAbsent == true`),
/// never dropped from the list.
public struct SourceFreshnessSnapshot: Codable, Equatable, Sendable, Identifiable {
    public enum Availability: String, Codable, Equatable, Sendable {
        case fresh
        case stale
        case unavailable          // never successfully synced
        case permissionWithheld   // the user has this source turned off
    }

    public let source: DataSource
    public let availability: Availability
    public let lastSyncedAt: Date?
    /// Age of the data as of briefing time, or nil when never synced.
    public let ageSeconds: TimeInterval?

    public var id: DataSource { source }

    /// The source contributed no data to this briefing — the UI must say so explicitly.
    public var isAbsent: Bool {
        availability == .unavailable || availability == .permissionWithheld
    }

    public init(source: DataSource, availability: Availability,
                lastSyncedAt: Date?, ageSeconds: TimeInterval?) {
        self.source = source
        self.availability = availability
        self.lastSyncedAt = lastSyncedAt
        self.ageSeconds = ageSeconds
    }

    /// Resolve a `SourceFreshness` (Core convention) into a serializable snapshot as of `now`.
    public init(freshness: SourceFreshness, asOf now: Date) {
        let availability: Availability
        switch freshness.status(asOf: now) {
        case .fresh: availability = .fresh
        case .stale: availability = .stale
        case .unavailable: availability = .unavailable
        case .permissionWithheld: availability = .permissionWithheld
        }
        self.init(source: freshness.source,
                  availability: availability,
                  lastSyncedAt: freshness.lastSuccessfulSync,
                  ageSeconds: freshness.age(asOf: now))
    }
}

/// The complete, deterministically-assembled Morning Briefing.
///
/// Assembled by `BriefingAssembler` from calendar events, goal state, yesterday's log, open
/// loops, and per-source freshness. This is the exact structured value Phase 5 will hand to
/// the LLM for a narrative — hence fully `Codable`.
public struct MorningBriefing: Codable, Equatable, Sendable {
    /// The day the briefing describes (start-of-day for `now`).
    public let date: Date
    /// The user's real calendar events for today (attributed, never mixed with agent events).
    public let realEvents: [BriefingEvent]
    /// Today's agent-owned calendar events (from the dedicated agent calendar).
    public let agentEvents: [BriefingEvent]
    /// Active, incomplete goal tasks whose window falls on today.
    public let dueTasks: [BriefingTask]
    /// Tasks past their acceptable window with no completion evidence (via `SlipDetector`).
    public let slippedItems: [BriefingTask]
    /// Yesterday's captured reality, if a `DailyLog` exists for it.
    public let yesterday: BriefingDailyLog?
    /// Unresolved open loops carried into today.
    public let openLoops: [BriefingOpenLoop]
    /// One freshness snapshot per source the briefing draws on (calendar/Gmail/HealthKit).
    public let sources: [SourceFreshnessSnapshot]
    /// The single recommended priority for today — highest-priority due task (headline/widget).
    public let topPriority: BriefingTask?

    public init(date: Date, realEvents: [BriefingEvent], agentEvents: [BriefingEvent],
                dueTasks: [BriefingTask], slippedItems: [BriefingTask],
                yesterday: BriefingDailyLog?, openLoops: [BriefingOpenLoop],
                sources: [SourceFreshnessSnapshot], topPriority: BriefingTask?) {
        self.date = date
        self.realEvents = realEvents
        self.agentEvents = agentEvents
        self.dueTasks = dueTasks
        self.slippedItems = slippedItems
        self.yesterday = yesterday
        self.openLoops = openLoops
        self.sources = sources
        self.topPriority = topPriority
    }

    /// Look up one source's snapshot (e.g. to render "Gmail — not connected").
    public func source(_ source: DataSource) -> SourceFreshnessSnapshot? {
        sources.first { $0.source == source }
    }

    /// Sources that contributed no data — surfaced explicitly so the briefing never implies
    /// completeness it does not have.
    public var absentSources: [SourceFreshnessSnapshot] { sources.filter(\.isAbsent) }
}
