import Foundation
import Core

/// Direct Google Calendar REST v3 client (LOCKED_DECISIONS #4). Reads the user's real
/// calendars; creates/updates/deletes **only** on the app-created agent-owned calendar,
/// enforced in code (Safety Rule #2) on top of the token's `calendar.app.created` grant,
/// which already makes real-calendar writes structurally impossible.
///
/// Idempotent writes use caller-supplied event IDs: a retried create sends the same ID, and
/// Google returns HTTP 409 for a duplicate — which we treat as success (fetch + return the
/// existing event), so a retry yields exactly one event.
public actor GoogleCalendarRESTClient: GoogleCalendarAPI {

    /// The display name of the dedicated agent-owned calendar (find-or-create by summary).
    public static let agentCalendarSummary = "Personal Ops Agent"

    private let tokenProvider: AccessTokenProviding
    private let transport: HTTPTransport
    private let status: IntegrationStatusReporting?
    private let clock: any Clock
    private let retryPolicy: RetryPolicy
    private let baseURL: URL

    /// Cached agent calendar ID once resolved (so writes don't re-resolve every call).
    private var cachedAgentCalendarID: String?

    public init(tokenProvider: AccessTokenProviding,
                transport: HTTPTransport,
                status: IntegrationStatusReporting? = nil,
                clock: any Clock = SystemClock(),
                retryPolicy: RetryPolicy = .standard,
                baseURL: URL = URL(string: "https://www.googleapis.com")!) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.status = status
        self.clock = clock
        self.retryPolicy = retryPolicy
        self.baseURL = baseURL
    }

    // MARK: Reads

    public func listCalendars() async throws -> [CalendarInfo] {
        let url = baseURL.appendingPathComponent("/calendar/v3/users/me/calendarList")
        let data = try await get(url)
        let decoded = try decode(CalendarListResponse.self, from: data)
        let infos = (decoded.items ?? []).map {
            CalendarInfo(id: $0.id,
                         summary: $0.summary ?? "",
                         isAgentOwned: ($0.summary ?? "") == Self.agentCalendarSummary)
        }
        await reportSynced(.calendar)
        return infos
    }

    public func ensureAgentCalendar() async throws -> String {
        if let cached = cachedAgentCalendarID { return cached }
        // Find an existing agent calendar first.
        let calendars = try await listCalendars()
        if let existing = calendars.first(where: { $0.isAgentOwned }) {
            cachedAgentCalendarID = existing.id
            return existing.id
        }
        // Create it.
        let url = baseURL.appendingPathComponent("/calendar/v3/calendars")
        let body = try JSONSerialization.data(withJSONObject: ["summary": Self.agentCalendarSummary])
        let data = try await send(method: "POST", url: url, body: body, source: .calendar)
        let created = try decode(CalendarResource.self, from: data)
        cachedAgentCalendarID = created.id
        return created.id
    }

    public func listEvents(calendarID: String, from: Date, to: Date) async throws -> [CalendarEventDTO] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/calendar/v3/calendars/\(encode(calendarID))/events"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: iso8601(from)),
            URLQueryItem(name: "timeMax", value: iso8601(to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime")
        ]
        let data = try await get(components.url!)
        let decoded = try decode(EventsListResponse.self, from: data)
        let agentID = cachedAgentCalendarID
        let events = (decoded.items ?? []).compactMap { item -> CalendarEventDTO? in
            guard let id = item.id,
                  let start = item.start?.resolvedDate(),
                  let end = item.end?.resolvedDate() else { return nil }
            return CalendarEventDTO(
                id: id,
                calendarID: calendarID,
                title: item.summary ?? "(no title)",
                start: start,
                end: end,
                isAgentOwned: calendarID == agentID)
        }
        await reportSynced(.calendar)
        return events
    }

    // MARK: Writes (agent-owned calendar ONLY)

    public func createEvent(_ event: CalendarEventDTO, idempotencyKey: String) async throws -> CalendarEventDTO {
        let agentID = try await requireAgentCalendar(for: event.calendarID)
        let eventID = GoogleEventID.make(from: idempotencyKey)
        let url = baseURL.appendingPathComponent("/calendar/v3/calendars/\(encode(agentID))/events")
        let body = try encodeEventBody(event, id: eventID)

        do {
            let data = try await send(method: "POST", url: url, body: body, source: .calendar)
            return try eventDTO(from: data, calendarID: agentID, fallbackID: eventID)
        } catch let error as AppError {
            // Idempotency: a duplicate ID means the event already exists (a prior attempt
            // succeeded server-side). Fetch and return it — exactly one event, not two.
            if case .data(.conflict) = error {
                return try await getEvent(id: eventID, calendarID: agentID)
            }
            throw error
        }
    }

    public func updateEvent(_ event: CalendarEventDTO) async throws -> CalendarEventDTO {
        let agentID = try await requireAgentCalendar(for: event.calendarID)
        let url = baseURL.appendingPathComponent(
            "/calendar/v3/calendars/\(encode(agentID))/events/\(encode(event.id))")
        let body = try encodeEventBody(event, id: nil)
        let data = try await send(method: "PUT", url: url, body: body, source: .calendar)
        return try eventDTO(from: data, calendarID: agentID, fallbackID: event.id)
    }

    public func deleteEvent(id: String, calendarID: String) async throws {
        let agentID = try await requireAgentCalendar(for: calendarID)
        let url = baseURL.appendingPathComponent(
            "/calendar/v3/calendars/\(encode(agentID))/events/\(encode(id))")
        _ = try await send(method: "DELETE", url: url, body: nil, source: .calendar)
    }

    // MARK: - Write guard

    /// Resolve + verify the target is the agent-owned calendar. A write aimed anywhere else
    /// is refused outright (Safety Rule #2) — belt-and-suspenders over the scope grant.
    private func requireAgentCalendar(for requestedCalendarID: String) async throws -> String {
        let agentID = try await ensureAgentCalendar()
        // Accept either the sentinel "agent" placeholder used upstream, or the real ID.
        guard requestedCalendarID == agentID || requestedCalendarID == "agent" else {
            throw AppError.integration(.unavailable(
                source: .calendar,
                reason: "Refused write to a non-agent calendar"))
        }
        return agentID
    }

    private func getEvent(id: String, calendarID: String) async throws -> CalendarEventDTO {
        let url = baseURL.appendingPathComponent(
            "/calendar/v3/calendars/\(encode(calendarID))/events/\(encode(id))")
        let data = try await get(url)
        return try eventDTO(from: data, calendarID: calendarID, fallbackID: id)
    }

    // MARK: - HTTP plumbing

    private func get(_ url: URL) async throws -> Data {
        try await send(method: "GET", url: url, body: nil, source: .calendar)
    }

    private func send(method: String, url: URL, body: Data?, source: DataSource) async throws -> Data {
        try await withRetry(policy: retryPolicy) {
            let token = try await self.tokenProvider.validAccessToken()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await self.transport.send(request)
            // A 409 (duplicate caller-supplied event ID) is a *non-retryable* conflict that
            // createEvent special-cases into an idempotent success — never retried.
            if response.statusCode == 409 { throw AppError.data(.conflict("event-exists")) }
            if let error = HTTPErrorMapper.error(for: response.statusCode, source: source, body: data) {
                throw error
            }
            return data
        }
    }

    private func reportSynced(_ source: DataSource) async {
        await status?.reportSynced(source, at: clock.now, threshold: 15 * 60)
    }

    // MARK: - Encoding / decoding

    private func encodeEventBody(_ event: CalendarEventDTO, id: String?) throws -> Data {
        var payload: [String: Any] = [
            "summary": event.title,
            "start": ["dateTime": iso8601(event.start)],
            "end": ["dateTime": iso8601(event.end)]
        ]
        if let id { payload["id"] = id }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func eventDTO(from data: Data, calendarID: String, fallbackID: String) throws -> CalendarEventDTO {
        let item = try decode(EventResource.self, from: data)
        return CalendarEventDTO(
            id: item.id ?? fallbackID,
            calendarID: calendarID,
            title: item.summary ?? "(no title)",
            start: item.start?.resolvedDate() ?? clock.now,
            end: item.end?.resolvedDate() ?? clock.now,
            isAgentOwned: true)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AppError.network(.malformedResponse) }
    }

    private func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - Wire DTOs (decode-only)

private struct CalendarListResponse: Decodable { let items: [CalendarResource]? }
private struct CalendarResource: Decodable {
    let id: String
    let summary: String?
}
private struct EventsListResponse: Decodable { let items: [EventResource]? }
private struct EventResource: Decodable {
    let id: String?
    let summary: String?
    let start: EventDateTime?
    let end: EventDateTime?
}
private struct EventDateTime: Decodable {
    let dateTime: String?
    let date: String?
    func resolvedDate() -> Date? {
        if let dateTime {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: dateTime) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: dateTime)
        }
        if let date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: date)
        }
        return nil
    }
}
