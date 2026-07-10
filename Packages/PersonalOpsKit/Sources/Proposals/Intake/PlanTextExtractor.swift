import Foundation

/// # PlanTextExtractor — conservative, deterministic plan-ish extraction from free text
///
/// Turns an untrusted chunk of message text into a *classification*, never into a write. Same
/// spirit as the Gmail extraction (Phase 4B): look for concrete dates/times and plan-ish
/// phrasing; when a concrete date is present, treat it as a schedulable event candidate;
/// otherwise treat the text as a note to remember. Nothing here is guessed into memory — the
/// caller turns the classification into a *pending* Proposal the user reviews.
///
/// Deterministic and LLM-free: date/time recognition uses Foundation's `NSDataDetector`, seeded
/// with an explicit reference date so relative phrases ("tomorrow at 3pm") resolve reproducibly.
/// Phase 6 (voice capture) can reuse this same extractor on a confirmed transcript.
public struct PlanTextExtractor: Sendable {
    public init() {}

    /// The default block length assumed for an extracted event when the text names a start but
    /// no explicit end.
    public static let defaultEventDuration: TimeInterval = 60 * 60

    /// What the text was classified as.
    public enum Classification: Sendable, Equatable {
        /// A concrete date/time was found — a schedulable event candidate.
        case event(EventCandidate)
        /// Valid text with no schedulable signal — remember it as a reviewable note.
        case note(String)
    }

    public struct EventCandidate: Sendable, Equatable {
        public let title: String
        public let start: Date
        public let end: Date
        public init(title: String, start: Date, end: Date) {
            self.title = title; self.start = start; self.end = end
        }
    }

    /// Classify `text`. `referenceDate` anchors relative date phrases. Returns `nil` only when
    /// the text has no usable content at all (empty/whitespace) — the caller treats that as a
    /// drop.
    public func classify(_ text: String, referenceDate: Date) -> Classification? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let (date, hasTime) = Self.firstDate(in: trimmed, referenceDate: referenceDate), hasTime {
            let title = Self.eventTitle(from: trimmed)
            return .event(EventCandidate(
                title: title,
                start: date,
                end: date.addingTimeInterval(Self.defaultEventDuration)))
        }
        return .note(trimmed)
    }

    // MARK: - Date/time recognition

    /// The first date match in the text, plus whether it carried a time-of-day. A bare calendar
    /// day with no time is *not* treated as schedulable (too ambiguous to place a block) — it
    /// falls through to a note, staying conservative.
    static func firstDate(in text: String, referenceDate: Date) -> (date: Date, hasTime: Bool)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: (Date, Bool)?
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let match, let date = match.date else { return }
            // `duration > 0` or an explicit time component signals a time-of-day was present.
            let hasTime = Self.mentionsTime(text) || match.duration > 0
            result = (date, hasTime)
            stop.pointee = true
        }
        return result
    }

    /// Heuristic: does the text mention a clock time ("3pm", "15:00", "9 am")? Used to decide a
    /// detected date is specific enough to schedule.
    static func mentionsTime(_ text: String) -> Bool {
        let patterns = [
            #"\b\d{1,2}\s*(?:am|pm)\b"#,          // 3pm, 9 am
            #"\b\d{1,2}:\d{2}\b"#                  // 15:00, 9:30
        ]
        let lower = text.lowercased()
        for p in patterns {
            if lower.range(of: p, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// A short event title from the message: the first sentence/line, trimmed to a sane length.
    static func eventTitle(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: { $0 == "\n" || $0 == "." })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? text
        let title = firstLine.isEmpty ? text : firstLine
        return String(title.prefix(80))
    }
}
