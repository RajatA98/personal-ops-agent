import XCTest
import SwiftData
import Core
import Fixtures
@testable import Data

/// Test-QA edge-case probe (Phase 8). The existing `MemoryLifecycleTests` proves a single
/// correction (revision 1 → 2). This exercises a DEEP revision chain — five successive
/// corrections — to confirm the append-only invariant holds at depth: history preserves every
/// revision in order, exactly one revision stays active, numbering is monotonic, and the default
/// query always resolves to the newest value (never a stale or arbitrary mid-chain revision).
final class MemoryDepthTests: XCTestCase {

    func test_deepCorrectionChain_keepsOneActive_preservesFullHistory() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 5_000_000))
        let context = try TestContainer.context()
        let store = MemoryStore(context: context, clock: clock)

        let pref = Preference(source: .user, key: "commute_mode", value: "v0")
        pref.factKey = "preference:commute_mode"
        try store.insert(pref)
        XCTAssertEqual(pref.revision, 1)

        // Correct five more times: v1 … v5.
        var latest = pref
        for i in 1...5 {
            clock.advance(by: 3600)
            latest = try store.correct(latest, reason: "change #\(i)") { $0.value = "v\(i)" }
            XCTAssertEqual(latest.revision, i + 1, "each correction increments the revision")
            XCTAssertNil(latest.supersededAt, "the newest revision is never itself superseded")
        }

        // History holds all six revisions, in ascending revision order, values v0…v5 preserved.
        let history = try store.history(Preference.self, factKey: "preference:commute_mode")
        XCTAssertEqual(history.count, 6)
        XCTAssertEqual(history.map(\.revision), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(history.map(\.value), ["v0", "v1", "v2", "v3", "v4", "v5"])
        // Every non-final revision is superseded (append-only audit — none deleted).
        XCTAssertTrue(history.dropLast().allSatisfy { $0.supersededAt != nil })

        // Exactly one active revision, and the default query resolves to the newest value.
        XCTAssertEqual(try store.activeRevisions(Preference.self, factKey: "preference:commute_mode").count, 1)
        let resolution = try store.resolve(Preference.self, factKey: "preference:commute_mode")
        guard case let .resolved(active) = resolution else {
            return XCTFail("expected a single resolved revision at chain depth 6, got \(resolution)")
        }
        XCTAssertEqual(active.revision, 6)
        XCTAssertEqual(active.value, "v5")
        XCTAssertEqual(active.appID, latest.appID)
    }
}
