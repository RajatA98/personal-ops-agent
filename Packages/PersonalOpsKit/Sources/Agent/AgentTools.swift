import Foundation
import SwiftData
import Core
import Data
import Integrations
import Goals
import Proposals
import Reasoning

/// How a tool is classified (AGENT_DESIGN §3). There is NO third class: a tool either reads
/// (executes immediately, side-effect-free) or proposes (creates a pending Proposal and stops).
public enum ToolKind: String, Equatable, Sendable {
    case read
    case propose
}

/// One tool the LLM may call. Declaration is the provider-neutral schema handed to the model;
/// `execute` runs the tool and returns a JSON result string that goes back into the transcript.
///
/// `@MainActor` because read tools drive the SwiftData `ModelContext` (a `MemoryStore`) and
/// propose tools drive the `@MainActor ProposalEngine`. Propose tools' ONLY side effect is
/// `ProposalEngine.enqueue` — they physically cannot approve or execute (the `ApprovalGrant`
/// that handlers require is un-forgeable, Phase 4A), so the worst case is a pending Proposal.
@MainActor
public protocol AgentTool {
    var declaration: ReasoningTool { get }
    var kind: ToolKind { get }
    func execute(_ call: ReasoningToolCall) async throws -> String
}

/// The seams the tools run against. Constructed on the `ModelContext`'s actor (the app's
/// `@MainActor`). Optional integration seams degrade honestly: a nil calendar/gmail/health
/// makes the corresponding tool return "not connected" rather than failing the whole turn.
@MainActor
public struct ToolContext {
    public let context: ModelContext
    public let clock: any Clock
    public let calendar: (any GoogleCalendarAPI)?
    public let gmail: (any GmailAPI)?
    public let health: (any HealthKitDataSource)?
    public let engine: ProposalEngine

    public init(context: ModelContext,
                clock: any Clock,
                calendar: (any GoogleCalendarAPI)?,
                gmail: (any GmailAPI)?,
                health: (any HealthKitDataSource)?,
                engine: ProposalEngine) {
        self.context = context
        self.clock = clock
        self.calendar = calendar
        self.gmail = gmail
        self.health = health
        self.engine = engine
    }

    var store: MemoryStore { MemoryStore(context: context, clock: clock) }
}

// MARK: - Shared encoding helpers

enum ToolJSON {
    static func string(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// A fresh ISO-8601 formatter per call — `ISO8601DateFormatter` is not `Sendable`, so we do
    /// not share a static instance across concurrent contexts.
    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static func date(_ date: Date) -> String { isoFormatter().string(from: date) }

    static func parseDate(_ any: Any?) -> Date? {
        guard let string = any as? String else { return nil }
        return isoFormatter().date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

private extension [String: Any] {
    func stringValue(_ key: String) -> String? { self[key] as? String }
}

// MARK: - Read tools

/// `search_memory(query, types?, date_range?)` — active-revision memory matching `query`.
@MainActor
struct SearchMemoryTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .read

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "search_memory",
            description: "Search the user's own memory (facts/preferences, decisions, open loops, daily-log notes, commitments, learned patterns) for entries matching a query. Returns matching entries with ids, type, a one-line summary, confidence, source and date. Returns an empty list when nothing matches.",
            parametersSchema: """
            {"type":"object","properties":{"query":{"type":"string","description":"words to match against memory contents"},"types":{"type":"array","items":{"type":"string","enum":["preference","open_loop","decision","daily_log","commitment","pattern"]},"description":"optional filter to only these memory types"}},"required":["query"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        let args = call.arguments
        let query = (args.stringValue("query") ?? "").lowercased()
        let typeFilter = Set((args["types"] as? [String]) ?? [])
        let now = ctx.clock.now
        var hits: [[String: Any]] = []

        func consider(_ typeLabel: String, _ id: UUID, _ content: String,
                      _ confidence: Double, _ source: String, _ date: Date) {
            if !typeFilter.isEmpty && !typeFilter.contains(typeLabel) { return }
            if !query.isEmpty && !content.lowercased().contains(query) { return }
            hits.append([
                "id": id.uuidString, "type": typeLabel, "content": content,
                "confidence": confidence, "source": source, "date": ToolJSON.date(date)
            ])
        }

        for p in try ctx.store.all(Preference.self) where p.isActive(asOf: now) {
            consider("preference", p.appID, "\(p.key): \(p.value)", p.confidence, p.source.rawValue, p.updatedAt)
        }
        for o in try ctx.store.all(OpenLoop.self) where o.isActive(asOf: now) {
            consider("open_loop", o.appID, o.detail.isEmpty ? o.title : "\(o.title) — \(o.detail)", o.confidence, o.source.rawValue, o.updatedAt)
        }
        for d in try ctx.store.all(Decision.self) where d.isActive(asOf: now) {
            consider("decision", d.appID, "\(d.topic): \(d.choice)\(d.rationale.isEmpty ? "" : " (\(d.rationale))")", d.confidence, d.source.rawValue, d.updatedAt)
        }
        for l in try ctx.store.all(DailyLog.self) where l.isActive(asOf: now) {
            consider("daily_log", l.appID, l.summary, l.confidence, l.source.rawValue, l.updatedAt)
        }
        for c in try ctx.store.all(Commitment.self) where c.isActive(asOf: now) {
            consider("commitment", c.appID, c.title, c.confidence, c.source.rawValue, c.updatedAt)
        }
        for pat in try ctx.store.all(Pattern.self) where pat.isActive(asOf: now) {
            consider("pattern", pat.appID, pat.detail.isEmpty ? pat.name : "\(pat.name): \(pat.detail)", pat.confidence, pat.source.rawValue, pat.updatedAt)
        }

        return ToolJSON.string(["results": hits, "count": hits.count])
    }
}

/// `get_goal_state(goal_id?)` — goals with plan/progress/slip status.
@MainActor
struct GetGoalStateTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .read
    private let slipDetector = SlipDetector()

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "get_goal_state",
            description: "Get the user's active goals with their tasks, recent progress, and which tasks have slipped. Pass a goal id to narrow to one goal; omit it for all active goals.",
            parametersSchema: """
            {"type":"object","properties":{"goal_id":{"type":"string","description":"optional goal id to fetch a single goal"}}}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        let now = ctx.clock.now
        let wanted = call.arguments.stringValue("goal_id")
        let goals = try ctx.store.all(Goal.self)
            .filter { $0.isActive(asOf: now) && $0.status == .active }
            .filter { wanted == nil || $0.appID.uuidString == wanted }

        let out: [[String: Any]] = goals.map { goal in
            let tasks = goal.tasks ?? []
            let progress = (goal.progress ?? []).filter { $0.isActive(asOf: now) }
            let rule = PlaybookLibrary.playbook(forKey: goal.playbookKey)?.slipRule
                ?? SlipRule(gracePeriod: 0, requiresCompletionEvidence: false)
            let slipped = slipDetector.slippedTasks(tasks: goal.tasks ?? [], progress: goal.progress ?? [], rule: rule, asOf: now)
            let slippedIDs = Set(slipped.map(\.appID))
            return [
                "id": goal.appID.uuidString,
                "title": goal.title,
                "playbook": goal.playbookKey,
                "targetDate": goal.targetDate.map(ToolJSON.date) as Any,
                "tasks": tasks.map { t -> [String: Any] in
                    [
                        "id": t.appID.uuidString, "title": t.title,
                        "isComplete": t.isComplete,
                        "flexibility": t.flexibility.rawValue,
                        "latestAcceptable": t.latestAcceptable.map(ToolJSON.date) as Any,
                        "slipped": slippedIDs.contains(t.appID)
                    ]
                },
                "recentProgress": progress.suffix(10).map { p -> [String: Any] in
                    ["metric": p.metricKey, "value": p.value, "note": p.note, "date": ToolJSON.date(p.updatedAt)]
                }
            ]
        }
        return ToolJSON.string(["goals": out, "count": out.count])
    }
}

/// `search_calendar(date_range, calendar?)` — events (real + agent-owned, attributed) in range.
@MainActor
struct SearchCalendarTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .read

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "search_calendar",
            description: "List calendar events between two ISO-8601 timestamps. Events are attributed as real (the user's own calendars) or agent-owned (blocks this app scheduled). If the calendar is not connected, that is reported honestly.",
            parametersSchema: """
            {"type":"object","properties":{"start":{"type":"string","description":"ISO-8601 start of range"},"end":{"type":"string","description":"ISO-8601 end of range"}},"required":["start","end"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        guard let calendar = ctx.calendar else {
            return ToolJSON.string(["available": false, "reason": "Calendar is not connected."])
        }
        let args = call.arguments
        let now = ctx.clock.now
        let from = ToolJSON.parseDate(args["start"]) ?? now
        let to = ToolJSON.parseDate(args["end"]) ?? now.addingTimeInterval(86_400)
        do {
            let agentID = try await calendar.ensureAgentCalendar()
            var events = try await calendar.listEvents(calendarID: "primary", from: from, to: to)
            let agentEvents = try await calendar.listEvents(calendarID: agentID, from: from, to: to)
            events.append(contentsOf: agentEvents)
            let mapped = events.map { e -> [String: Any] in
                ["id": e.id, "title": e.title, "start": ToolJSON.date(e.start),
                 "end": ToolJSON.date(e.end), "isAgentOwned": e.isAgentOwned]
            }
            return ToolJSON.string(["available": true, "events": mapped, "count": mapped.count])
        } catch let error as AppError {
            return ToolJSON.string(["available": false, "reason": error.userMessage])
        }
    }
}

/// `search_gmail(query, date_range?)` — message metadata + snippets (never body).
@MainActor
struct SearchGmailTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .read

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "search_gmail",
            description: "Search the user's email for messages matching a query. Returns only metadata (subject, sender, date) and a short snippet — never the full body. If Gmail is not connected, that is reported honestly.",
            parametersSchema: """
            {"type":"object","properties":{"query":{"type":"string"},"since":{"type":"string","description":"optional ISO-8601 lower bound on received date"}},"required":["query"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        guard let gmail = ctx.gmail else {
            return ToolJSON.string(["available": false, "reason": "Gmail is not connected."])
        }
        let args = call.arguments
        do {
            let messages = try await gmail.listRecentMessages(
                query: args.stringValue("query"),
                since: ToolJSON.parseDate(args["since"]))
            let mapped = messages.map { m -> [String: Any] in
                ["subject": m.subject ?? "", "sender": m.sender ?? "",
                 "date": ToolJSON.date(m.receivedDate), "snippet": m.snippet ?? ""]
            }
            return ToolJSON.string(["available": true, "messages": mapped, "count": mapped.count])
        } catch let error as AppError {
            return ToolJSON.string(["available": false, "reason": error.userMessage])
        }
    }
}

/// `get_health_summary(date_range)` — summarized sleep/recovery only (never raw records).
@MainActor
struct GetHealthSummaryTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .read

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "get_health_summary",
            description: "Get summarized sleep and recovery signals (sleep hours, resting heart rate, HRV) for a date range. Returns summaries only — never raw health records. If health data is unavailable or turned off, that is reported honestly.",
            parametersSchema: """
            {"type":"object","properties":{"start":{"type":"string","description":"ISO-8601 start"},"end":{"type":"string","description":"ISO-8601 end"}},"required":["start","end"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        guard let health = ctx.health else {
            return ToolJSON.string(["available": false, "reason": "Health data is not available."])
        }
        let args = call.arguments
        let now = ctx.clock.now
        let from = ToolJSON.parseDate(args["start"]) ?? now.addingTimeInterval(-7 * 86_400)
        let to = ToolJSON.parseDate(args["end"]) ?? now
        guard from <= to else {
            return ToolJSON.string(["available": true, "summaries": [], "count": 0])
        }
        do {
            let summaries = try await health.summary(for: from...to)
            let mapped = summaries.map { s -> [String: Any] in
                ["date": ToolJSON.date(s.date),
                 "sleepHours": s.sleepHours as Any,
                 "restingHeartRate": s.restingHeartRate as Any,
                 "hrv": s.hrv as Any]
            }
            return ToolJSON.string(["available": true, "summaries": mapped, "count": mapped.count])
        } catch {
            return ToolJSON.string(["available": false, "reason": "Health data is turned off or unavailable."])
        }
    }
}

/// `get_daily_log(date)` — the captured reality for a given day.
@MainActor
struct GetDailyLogTool: AgentTool {
    let ctx: ToolContext
    let kind: ToolKind = .read

    var declaration: ReasoningTool {
        ReasoningTool(
            name: "get_daily_log",
            description: "Get the user's captured daily-log note for a specific day (ISO-8601 date, e.g. 2026-07-09). Returns the note if one was recorded that day, or nothing if not.",
            parametersSchema: """
            {"type":"object","properties":{"date":{"type":"string","description":"the day, ISO-8601 (date or datetime)"}},"required":["date"]}
            """)
    }

    func execute(_ call: ReasoningToolCall) async throws -> String {
        let now = ctx.clock.now
        let day = ToolJSON.parseDate(call.arguments["date"])
            ?? (call.arguments.stringValue("date").flatMap { dateOnly($0) })
        guard let day else {
            return ToolJSON.string(["found": false, "reason": "Could not parse the date."])
        }
        let dayString = Self.dayFormatter().string(from: day)
        let key = "daily_log:" + dayString
        let logs = try ctx.store.all(DailyLog.self)
            .filter { $0.isActive(asOf: now) }
            .filter { $0.factKey == key || Self.dayFormatter().string(from: $0.logDate) == dayString }
        if let log = logs.first {
            return ToolJSON.string(["found": true, "date": ToolJSON.date(log.logDate), "summary": log.summary])
        }
        return ToolJSON.string(["found": false])
    }

    private func dateOnly(_ s: String) -> Date? {
        Self.dayFormatter().date(from: String(s.prefix(10)))
    }

    static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}
