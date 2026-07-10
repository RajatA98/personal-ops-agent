import Foundation
import Core

/// Transport DTO for a calendar event. This is a lightweight transfer type, **not** a
/// persistence model — SwiftData entities arrive in Phase 1. `isAgentOwned` distinguishes
/// the dedicated agent-owned calendar (writable) from the user's real calendars (read-only).
public struct CalendarEventDTO: Equatable, Sendable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAgentOwned: Bool

    public init(id: String, calendarID: String, title: String,
                start: Date, end: Date, isAgentOwned: Bool) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAgentOwned = isAgentOwned
    }
}

/// Lightweight descriptor for one of the user's calendars (from `calendarList`).
public struct CalendarInfo: Equatable, Sendable {
    public let id: String
    public let summary: String
    /// `true` if this is the app-created agent-owned calendar (matched by summary).
    public let isAgentOwned: Bool

    public init(id: String, summary: String, isAgentOwned: Bool) {
        self.id = id
        self.summary = summary
        self.isAgentOwned = isAgentOwned
    }
}

/// Read from real calendars; create/update/delete only on the agent-owned calendar with
/// caller-provided idempotency keys (Safety Rule #2). Real implementation lands in Phase 2.
///
/// The write methods (`createEvent`/`updateEvent`/`deleteEvent`) target the agent-owned
/// calendar only — implementations MUST reject writes to any other calendar. Reads
/// (`listEvents`/`listCalendars`) span the user's real calendars and are never destructive.
public protocol GoogleCalendarAPI: Sendable {
    /// List the user's calendars (real + agent-owned).
    func listCalendars() async throws -> [CalendarInfo]

    /// Find the dedicated agent-owned calendar, creating it if it does not exist. Returns its
    /// calendar ID. This is the ONLY calendar the app is allowed to write to.
    func ensureAgentCalendar() async throws -> String

    /// Read events from any calendar in `[from, to]`.
    func listEvents(calendarID: String, from: Date, to: Date) async throws -> [CalendarEventDTO]

    /// Idempotent create on the agent-owned calendar: retrying with the same `idempotencyKey`
    /// must yield exactly one event (caller-supplied event ID → Google 409 on duplicate).
    func createEvent(_ event: CalendarEventDTO, idempotencyKey: String) async throws -> CalendarEventDTO

    /// Update an existing agent-owned event (rejected for non-agent calendars).
    func updateEvent(_ event: CalendarEventDTO) async throws -> CalendarEventDTO

    /// Delete an agent-owned event (rejected for non-agent calendars).
    func deleteEvent(id: String, calendarID: String) async throws
}
