import Foundation
import Core
import Integrations

/// Protocol-based fake for `GoogleCalendarAPI` with minimal seed data. Records
/// `createEvent` calls (with idempotency keys) so Phase 2/4A tests can assert
/// exactly-once write semantics. Real REST implementation lands in Phase 2.
public final class FakeGoogleCalendarAPI: GoogleCalendarAPI, @unchecked Sendable {

    public struct CreatedEvent: Equatable, Sendable {
        public let event: CalendarEventDTO
        public let idempotencyKey: String
    }

    private let lock = NSLock()
    private var seededEvents: [CalendarEventDTO]
    private var _createdEvents: [CreatedEvent] = []
    private var _writeCallCount = 0

    public init(events: [CalendarEventDTO] = []) {
        self.seededEvents = events
    }

    public var createdEvents: [CreatedEvent] {
        lock.withLock { _createdEvents }
    }

    /// Total number of *write* method invocations (create + update + delete), counted even
    /// when a create is idempotently deduped. Lets tests assert a code path performed **zero**
    /// calendar writes — e.g. Phase 3A's engine, which must only *preview* schedules, never
    /// write them.
    public var writeCallCount: Int {
        lock.withLock { _writeCallCount }
    }

    /// Fixed agent-calendar ID the fake writes to.
    public static let agentCalendarID = "agent"

    public func listCalendars() async throws -> [CalendarInfo] {
        [
            CalendarInfo(id: "primary", summary: "My Calendar", isAgentOwned: false),
            CalendarInfo(id: Self.agentCalendarID, summary: "Personal Ops Agent", isAgentOwned: true)
        ]
    }

    public func ensureAgentCalendar() async throws -> String { Self.agentCalendarID }

    public func updateEvent(_ event: CalendarEventDTO) async throws -> CalendarEventDTO {
        lock.withLock {
            _writeCallCount += 1
            if let idx = seededEvents.firstIndex(where: { $0.id == event.id }) {
                seededEvents[idx] = event
            }
        }
        return event
    }

    public func deleteEvent(id: String, calendarID: String) async throws {
        lock.withLock {
            _writeCallCount += 1
            seededEvents.removeAll { $0.id == id }
        }
    }

    public func listEvents(calendarID: String, from: Date, to: Date) async throws -> [CalendarEventDTO] {
        lock.withLock { seededEvents.filter { $0.start >= from && $0.start <= to } }
    }

    public func createEvent(_ event: CalendarEventDTO, idempotencyKey: String) async throws -> CalendarEventDTO {
        lock.withLock {
            _writeCallCount += 1
            // Idempotent: a repeat key does not append a second record.
            if !_createdEvents.contains(where: { $0.idempotencyKey == idempotencyKey }) {
                _createdEvents.append(CreatedEvent(event: event, idempotencyKey: idempotencyKey))
                seededEvents.append(event)
            }
        }
        return event
    }

    /// Minimal, deterministic seed: one real event + one agent-owned event.
    public static func seeded(referenceDate: Date = Date(timeIntervalSince1970: 1_000_000)) -> FakeGoogleCalendarAPI {
        let real = CalendarEventDTO(
            id: "real-standup",
            calendarID: "primary",
            title: "Team standup",
            start: referenceDate.addingTimeInterval(3600),
            end: referenceDate.addingTimeInterval(5400),
            isAgentOwned: false)
        let agent = CalendarEventDTO(
            id: "agent-longrun",
            calendarID: "agent",
            title: "Long run (training)",
            start: referenceDate.addingTimeInterval(28800),
            end: referenceDate.addingTimeInterval(34200),
            isAgentOwned: true)
        return FakeGoogleCalendarAPI(events: [real, agent])
    }
}
