import XCTest
import Foundation
import Core
import Integrations
@testable import Signals

/// Deterministic extraction: same input → same output, conservative (under-proposes).
final class GmailSignalExtractorTests: XCTestCase {

    private func utcExtractor() -> GmailSignalExtractor {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return GmailSignalExtractor(calendar: cal)
    }

    /// A fixed Thursday (2021-01-07 is a Thursday) 09:00 UTC reference receive date.
    private let received = Date(timeIntervalSince1970: 1_609_837_200)

    func test_meetingWithTime_producesEventProposal() {
        let extractor = utcExtractor()
        let msg = GmailMessageMetadata(
            messageID: "m1", threadID: "t1", receivedDate: received, scanTimestamp: received,
            snippet: "Interview confirmed for Thursday at 3pm.",
            subject: "Interview confirmed for Thursday 3pm",
            sender: "Recruiting <no-reply@jobs.example.com>")
        guard case let .event(title, start, end, confidence)? = extractor.extract(from: msg) else {
            return XCTFail("expected an event signal")
        }
        XCTAssertEqual(title, "Interview confirmed for Thursday 3pm")
        // Thursday == received day, 15:00 UTC.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.component(.hour, from: start), 15)
        XCTAssertEqual(end.timeIntervalSince(start), 3600)
        XCTAssertGreaterThanOrEqual(confidence, 0.6)
    }

    func test_extractionIsDeterministic() {
        let msg = GmailMessageMetadata(
            messageID: "m1", threadID: "t1", receivedDate: received, scanTimestamp: received,
            snippet: "Team sync tomorrow at 10:30", subject: "Team sync",
            sender: "a@b.com")
        XCTAssertEqual(utcExtractor().extract(from: msg), utcExtractor().extract(from: msg))
    }

    func test_noMeetingKeyword_orNoTime_underProposes() {
        let extractor = utcExtractor()
        // Meeting-ish but no time → no event.
        let m1 = GmailMessageMetadata(messageID: "m1", threadID: "t1", receivedDate: received,
                                      scanTimestamp: received, snippet: "Let's set up a meeting sometime",
                                      subject: "Coffee?", sender: "a@b.com")
        if case .event = extractor.extract(from: m1) { XCTFail("should not extract an event without a time") }
        // Time but no meeting keyword and no fact keyword → nothing.
        let m2 = GmailMessageMetadata(messageID: "m2", threadID: "t2", receivedDate: received,
                                      scanTimestamp: received, snippet: "The number is 3pm-ish shipments",
                                      subject: "Newsletter", sender: "a@b.com")
        XCTAssertNil(extractor.extract(from: m2))
    }

    func test_factKeyword_producesRememberFact() {
        let extractor = utcExtractor()
        let msg = GmailMessageMetadata(messageID: "m1", threadID: "t1", receivedDate: received,
                                       scanTimestamp: received, snippet: "Your race registration receipt",
                                       subject: "Your race registration receipt",
                                       sender: "receipts@raceday.example.com")
        guard case .fact? = extractor.extract(from: msg) else { return XCTFail("expected a fact signal") }
    }

    func test_weekdayResolution_picksNextOccurrence() {
        let extractor = utcExtractor()
        // Received Thursday; "Monday 9am" → next Monday (received + 4 days).
        let msg = GmailMessageMetadata(messageID: "m1", threadID: "t1", receivedDate: received,
                                       scanTimestamp: received, snippet: "Call on Monday at 9am",
                                       subject: "Kickoff call", sender: "a@b.com")
        guard case let .event(_, start, _, _)? = extractor.extract(from: msg) else {
            return XCTFail("expected event")
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.component(.weekday, from: start), 2) // Monday
        XCTAssertEqual(cal.component(.hour, from: start), 9)
        XCTAssertTrue(start > received)
    }

    func test_sourcePattern_stableAcrossVolatileParts() {
        let extractor = utcExtractor()
        let a = GmailMessageMetadata(messageID: "m1", threadID: "t1", receivedDate: received,
                                     scanTimestamp: received, snippet: "",
                                     subject: "Interview confirmed for Thursday 3pm",
                                     sender: "Recruiting <no-reply@jobs.example.com>")
        let b = GmailMessageMetadata(messageID: "m2", threadID: "t2", receivedDate: received,
                                     scanTimestamp: received, snippet: "",
                                     subject: "Interview confirmed for Monday 11am",
                                     sender: "Talent <no-reply@jobs.example.com>")
        // Same sender domain + same subject skeleton → identical downrank pattern.
        XCTAssertEqual(extractor.sourcePattern(for: a), extractor.sourcePattern(for: b))
        XCTAssertTrue(extractor.sourcePattern(for: a).hasPrefix("jobs.example.com|"))

        // A different sender domain must yield a different pattern.
        let c = GmailMessageMetadata(messageID: "m3", threadID: "t3", receivedDate: received,
                                     scanTimestamp: received, snippet: "",
                                     subject: "Interview confirmed for Friday 2pm",
                                     sender: "hr@other.example.org")
        XCTAssertNotEqual(extractor.sourcePattern(for: a), extractor.sourcePattern(for: c))
    }
}
