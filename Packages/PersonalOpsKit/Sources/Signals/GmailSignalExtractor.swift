import Foundation
import Core
import Integrations

/// # GmailSignalExtractor — deterministic, LLM-free classification (Phase 4B)
///
/// Turns a scanned `GmailMessageMetadata` (subject + snippet + headers, **never a body**) into
/// at most one `GmailSignal`: a calendar-event candidate or a remember-fact candidate. There is
/// **no model call anywhere** — every decision is a pure function of the text and an injected
/// `Calendar`, so the same input always yields the same output (the tests assert byte-stable
/// results). Phase 5 may layer an LLM classifier *on top* of this seam, but the deterministic
/// path here must remain the floor: it never fabricates, and it can be re-run offline.
///
/// ## Conservative by construction (PRD risk note: bias to under-proposing)
/// A false positive here spends the user's trust in the Ops Inbox, so extraction refuses more
/// than it accepts:
///   • an **event** requires BOTH a meeting-ish keyword AND a parseable clock time,
///   • a **fact** requires an explicit factual keyword and only fires when there is no event,
///   • anything ambiguous returns `nil` (no proposal).
public struct GmailSignalExtractor: Sendable {

    /// The calendar used to resolve weekday/relative-day + clock-time into an absolute `Date`.
    /// Tests inject a UTC calendar for determinism; the app uses `.current`.
    public var calendar: Calendar

    /// Minimum confidence a candidate must clear to be emitted (under-proposing guard).
    public var eventThreshold: Double
    public var factThreshold: Double

    public init(calendar: Calendar = {
                    var c = Calendar(identifier: .gregorian)
                    c.timeZone = TimeZone(identifier: "UTC") ?? .current
                    return c
                }(),
                eventThreshold: Double = 0.6,
                factThreshold: Double = 0.6) {
        self.calendar = calendar
        self.eventThreshold = eventThreshold
        self.factThreshold = factThreshold
    }

    // MARK: - Result type

    public enum GmailSignal: Equatable, Sendable {
        case event(title: String, start: Date, end: Date, confidence: Double)
        case fact(key: String, value: String, confidence: Double)
    }

    // MARK: - Vocabulary (deterministic keyword sets)

    private static let meetingKeywords = [
        "meeting", "call", "interview", "invite", "invitation", "appointment",
        "rsvp", "scheduled", "sync", "1:1", "standup", "stand-up", "demo",
        "hold", "webinar", "session", "catch up", "catch-up"
    ]
    private static let factKeywords = [
        "receipt", "confirmed", "confirmation", "registered", "registration",
        "deadline", "due", "order", "invoice", "renewal", "expires"
    ]
    private static let weekdays: [(name: String, index: Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
        ("thursday", 5), ("friday", 6), ("saturday", 7)
    ]

    // MARK: - Extraction

    public func extract(from message: GmailMessageMetadata) -> GmailSignal? {
        let subject = message.subject ?? ""
        let snippet = message.snippet ?? ""
        let haystack = "\(subject) \(snippet)".lowercased()
        guard !haystack.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        // --- Event path: keyword AND a parseable time. ---
        let hasMeetingKeyword = Self.meetingKeywords.contains { haystack.contains($0) }
        if hasMeetingKeyword, let time = parseClockTime(in: haystack) {
            let dayInfo = parseDay(in: haystack)
            let start = resolveDate(base: message.receivedDate, day: dayInfo,
                                    hour: time.hour, minute: time.minute)
            let end = start.addingTimeInterval(3600) // conservative default 1h block
            // Confidence: keyword+time is the floor; a day reference adds confidence.
            let confidence = 0.6 + (dayInfo != nil ? 0.3 : 0.0)
            if confidence >= eventThreshold {
                return .event(title: eventTitle(subject: subject, snippet: snippet),
                              start: start, end: end, confidence: confidence)
            }
        }

        // --- Fact path: explicit factual keyword, and only when no event fired. ---
        if let hit = Self.factKeywords.first(where: { haystack.contains($0) }) {
            let confidence = 0.6
            if confidence >= factThreshold {
                let value = factValue(subject: subject, snippet: snippet)
                return .fact(key: "gmail_fact:\(hit)", value: value, confidence: confidence)
            }
        }

        return nil
    }

    // MARK: - Source pattern (the downranking key)

    /// The **stable** descriptor "mark as wrong" downranks against: sender domain + a normalized
    /// subject *shape*. It deliberately strips the volatile parts (dates, times, weekday names,
    /// digits) so two messages from the same sender about the same *kind* of thing — e.g.
    /// "Interview confirmed for Thursday 3pm" and "Interview confirmed for Monday 2pm" — collapse
    /// to the same pattern. That is what makes rejecting one suppress the *others*, not just the
    /// exact thread (the thread itself is caught by the `proposal:gmail:<threadID>` factKey).
    public func sourcePattern(for message: GmailMessageMetadata) -> String {
        let domain = senderDomain(message.sender)
        let shape = subjectShape(message.subject ?? message.snippet ?? "")
        return "\(domain)|\(shape)"
    }

    /// Extract the lowercased domain from a `From` header (`"Name <user@domain.com>"` → `domain.com`).
    public func senderDomain(_ sender: String?) -> String {
        guard let sender, let at = sender.firstIndex(of: "@") else { return "unknown-sender" }
        let after = sender[sender.index(after: at)...]
        let domain = after.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let cleaned = domain.lowercased()
        return cleaned.isEmpty ? "unknown-sender" : cleaned
    }

    /// Normalize a subject to a stable skeleton: lowercase, drop weekday/relative-day words,
    /// clock times, digits, and punctuation; collapse whitespace.
    public func subjectShape(_ subject: String) -> String {
        var text = subject.lowercased()
        for (name, _) in Self.weekdays { text = text.replacingOccurrences(of: name, with: " ") }
        text = text.replacingOccurrences(of: "today", with: " ")
        text = text.replacingOccurrences(of: "tomorrow", with: " ")
        // Remove clock-time tokens and any standalone digits.
        text = regexReplace(text, pattern: "\\b\\d{1,2}(:\\d{2})?\\s*(am|pm)\\b", with: " ")
        text = regexReplace(text, pattern: "\\b([01]?\\d|2[0-3]):[0-5]\\d\\b", with: " ")
        text = regexReplace(text, pattern: "\\d+", with: " ")
        // Punctuation → space.
        text = regexReplace(text, pattern: "[^a-z ]", with: " ")
        // Collapse whitespace.
        text = regexReplace(text, pattern: "\\s+", with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Deterministic date/time parsing

    struct DayReference: Equatable { enum Kind: Equatable { case weekday(Int); case today; case tomorrow }
        let kind: Kind }

    struct ClockTime: Equatable { let hour: Int; let minute: Int }

    func parseClockTime(in text: String) -> ClockTime? {
        // 12-hour with am/pm, e.g. "3pm", "3:30 pm".
        if let m = firstMatch(in: text, pattern: "\\b(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\b") {
            var hour = m[1].flatMap { Int($0) } ?? 0
            let minute = m[2].flatMap { Int($0) } ?? 0
            let meridiem = m[3] ?? "am"
            if meridiem == "pm" && hour != 12 { hour += 12 }
            if meridiem == "am" && hour == 12 { hour = 0 }
            if (0...23).contains(hour) && (0...59).contains(minute) { return ClockTime(hour: hour, minute: minute) }
        }
        // 24-hour explicit, e.g. "15:00" (requires the colon to avoid matching bare numbers).
        if let m = firstMatch(in: text, pattern: "\\b([01]?\\d|2[0-3]):([0-5]\\d)\\b") {
            let hour = m[1].flatMap { Int($0) } ?? 0
            let minute = m[2].flatMap { Int($0) } ?? 0
            return ClockTime(hour: hour, minute: minute)
        }
        return nil
    }

    func parseDay(in text: String) -> DayReference? {
        if text.contains("tomorrow") { return DayReference(kind: .tomorrow) }
        if text.contains("today") { return DayReference(kind: .today) }
        for (name, index) in Self.weekdays where text.contains(name) {
            return DayReference(kind: .weekday(index))
        }
        return nil
    }

    /// Resolve an absolute start `Date` from the message's received date + parsed day/time, using
    /// the injected calendar (UTC in tests → fully deterministic).
    func resolveDate(base: Date, day: DayReference?, hour: Int, minute: Int) -> Date {
        var startOfBaseDay = calendar.startOfDay(for: base)
        switch day?.kind {
        case .tomorrow:
            startOfBaseDay = calendar.date(byAdding: .day, value: 1, to: startOfBaseDay) ?? startOfBaseDay
        case .weekday(let target):
            let current = calendar.component(.weekday, from: startOfBaseDay)
            let delta = ((target - current) + 7) % 7  // next occurrence on/after base day
            startOfBaseDay = calendar.date(byAdding: .day, value: delta, to: startOfBaseDay) ?? startOfBaseDay
        case .today, .none:
            break
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfBaseDay) ?? startOfBaseDay
    }

    // MARK: - Titles / values

    private func eventTitle(subject: String, snippet: String) -> String {
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return firstSentence(of: snippet)
    }

    private func factValue(subject: String, snippet: String) -> String {
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return firstSentence(of: snippet)
    }

    private func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.firstIndex(where: { $0 == "." || $0 == "\n" }) {
            return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    // MARK: - Regex helpers (deterministic)

    private func regexReplace(_ text: String, pattern: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    /// First match's capture groups (index 0 = whole match). Missing optional groups are `nil`.
    private func firstMatch(in text: String, pattern: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            let r = match.range(at: i)
            guard r.location != NSNotFound, let sr = Range(r, in: text) else { return nil }
            return String(text[sr])
        }
    }
}
