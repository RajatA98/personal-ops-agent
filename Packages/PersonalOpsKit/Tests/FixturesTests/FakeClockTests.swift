import XCTest
import Core
@testable import Fixtures

final class FakeClockTests: XCTestCase {

    func test_startsAtProvidedInstant() {
        let start = Date(timeIntervalSince1970: 500)
        let clock = FakeClock(now: start)
        XCTAssertEqual(clock.now, start)
    }

    func test_advanceMovesTimeForward() {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        clock.advance(by: 3600)
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 3600))
    }

    func test_setJumpsToExactInstant() {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        let target = Date(timeIntervalSince1970: 12345)
        clock.set(to: target)
        XCTAssertEqual(clock.now, target)
    }

    func test_conformsToCoreClock() {
        let clock: any Clock = FakeClock(now: Date(timeIntervalSince1970: 7))
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 7))
    }
}
