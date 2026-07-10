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

/// Read from real calendars; create/update/delete only on the agent-owned calendar with
/// caller-provided idempotency keys (Safety Rule #2). Real implementation lands in Phase 2.
public protocol GoogleCalendarAPI: Sendable {
    func listEvents(calendarID: String, from: Date, to: Date) async throws -> [CalendarEventDTO]
    /// Idempotent create: retrying with the same `idempotencyKey` must yield one event.
    func createEvent(_ event: CalendarEventDTO, idempotencyKey: String) async throws -> CalendarEventDTO
}
