import XCTest
@testable import Core

final class SourceFreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func test_recentSync_isFresh() {
        let f = SourceFreshness(source: .calendar,
                                lastSuccessfulSync: now.addingTimeInterval(-60),
                                stalenessThreshold: 3600)
        XCTAssertEqual(f.status(asOf: now), .fresh)
        XCTAssertFalse(f.isDegraded(asOf: now))
    }

    func test_oldSync_isStale() {
        let f = SourceFreshness(source: .calendar,
                                lastSuccessfulSync: now.addingTimeInterval(-7200),
                                stalenessThreshold: 3600)
        XCTAssertEqual(f.status(asOf: now), .stale)
        XCTAssertTrue(f.isDegraded(asOf: now))
    }

    func test_neverSynced_isUnavailable() {
        let f = SourceFreshness(source: .gmail, lastSuccessfulSync: nil, stalenessThreshold: 3600)
        XCTAssertEqual(f.status(asOf: now), .unavailable)
        XCTAssertTrue(f.isDegraded(asOf: now))
    }
}
