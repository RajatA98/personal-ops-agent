import Foundation
import Core

/// # Typed Proposal payloads
///
/// A `Proposal.payload` is an opaque JSON string on the persisted model (Phase 1 kept the
/// stored shape generic so it could store any type's action without the Data layer knowing
/// the semantics). Phase 4A gives each `ProposalType` a concrete, `Codable` payload struct;
/// the matching handler is the *only* code that decodes it. Encoding is centralized in
/// `ProposalPayloadCoder` so a builder and its handler always agree on the wire format.
///
/// Adding a new `ProposalType` means adding a payload here and a handler — there is no
/// generic "do whatever the JSON says" path, by design (Safety Rule #1).

/// `remember_fact` → persist a `Preference` memory fact (the general key/value fact store;
/// goal progress and plan edits have their own dedicated proposal types).
public struct RememberFactPayload: Codable, Equatable, Sendable {
    public var factKey: String
    public var key: String
    public var value: String
    public var confidence: Double
    public init(factKey: String, key: String, value: String, confidence: Double = 1.0) {
        self.factKey = factKey; self.key = key; self.value = value; self.confidence = confidence
    }
}

/// `create_agent_calendar_event` → one idempotent write to the agent-owned calendar.
/// `idempotencyKey` is the caller-provided key Phase 2's write path dedupes on; seeding it
/// from a stable `GoalTask.appID` is what makes re-deriving the same proposal a no-op.
public struct CreateAgentCalendarEventPayload: Codable, Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var idempotencyKey: String
    public init(title: String, start: Date, end: Date, idempotencyKey: String) {
        self.title = title; self.start = start; self.end = end; self.idempotencyKey = idempotencyKey
    }
}

/// `update_agent_calendar_event` → update an existing agent-owned event (agent calendar only).
public struct UpdateAgentCalendarEventPayload: Codable, Equatable, Sendable {
    public var eventID: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public init(eventID: String, calendarID: String, title: String, start: Date, end: Date) {
        self.eventID = eventID; self.calendarID = calendarID
        self.title = title; self.start = start; self.end = end
    }
}

/// `modify_goal_plan` → correct a `GoalTask` (a structural child; its "correction" is a plan
/// modification, not a memory revision — Phase 1's contract). Only the non-nil fields apply.
public struct ModifyGoalPlanPayload: Codable, Equatable, Sendable {
    public var goalTaskAppID: UUID
    public var newTitle: String?
    public var newEarliestAcceptable: Date?
    public var newLatestAcceptable: Date?
    public var newExpectedDuration: TimeInterval?
    public var markComplete: Bool?
    public init(goalTaskAppID: UUID, newTitle: String? = nil,
                newEarliestAcceptable: Date? = nil, newLatestAcceptable: Date? = nil,
                newExpectedDuration: TimeInterval? = nil, markComplete: Bool? = nil) {
        self.goalTaskAppID = goalTaskAppID
        self.newTitle = newTitle
        self.newEarliestAcceptable = newEarliestAcceptable
        self.newLatestAcceptable = newLatestAcceptable
        self.newExpectedDuration = newExpectedDuration
        self.markComplete = markComplete
    }
}

/// `mark_goal_progress` → append one `GoalProgress` entry (an append log; each entry is its
/// own memory fact).
public struct MarkGoalProgressPayload: Codable, Equatable, Sendable {
    public var goalAppID: UUID?
    public var progressFactKey: String
    public var metricKey: String
    public var value: Double
    public var note: String
    public init(goalAppID: UUID?, progressFactKey: String, metricKey: String,
                value: Double, note: String = "") {
        self.goalAppID = goalAppID
        self.progressFactKey = progressFactKey
        self.metricKey = metricKey
        self.value = value
        self.note = note
    }
}

/// `snooze_open_loop` → defer an `OpenLoop` until a later date (sets its `snoozedUntil`).
public struct SnoozeOpenLoopPayload: Codable, Equatable, Sendable {
    public var openLoopAppID: UUID
    public var snoozeUntil: Date
    public init(openLoopAppID: UUID, snoozeUntil: Date) {
        self.openLoopAppID = openLoopAppID; self.snoozeUntil = snoozeUntil
    }
}

/// `dismiss_signal` → mark a flagged signal (an `OpenLoop`) resolved — the agent proposed it
/// as noise / no-longer-relevant and the user agreed.
public struct DismissSignalPayload: Codable, Equatable, Sendable {
    public var openLoopAppID: UUID
    public var reason: String
    public init(openLoopAppID: UUID, reason: String = "") {
        self.openLoopAppID = openLoopAppID; self.reason = reason
    }
}

/// Central JSON coder for proposal payloads. One instance so every builder and handler use
/// identical date/format settings (round-trip is exact).
public enum ProposalPayloadCoder {
    public static func encode<T: Encodable>(_ payload: T) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else { throw ProposalError.malformedPayload }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProposalError.malformedPayload
        }
    }
}
