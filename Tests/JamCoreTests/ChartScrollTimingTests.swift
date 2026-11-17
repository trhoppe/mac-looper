import XCTest
@testable import JamCore

final class ChartScrollTimingTests: XCTestCase {
    func testSongLengthsInSecondsMinutesAndHours() {
        XCTAssertEqual(ChartScrollTiming.duration("225"), 225)
        XCTAssertEqual(ChartScrollTiming.duration(" 3:45 "), 225)
        XCTAssertEqual(ChartScrollTiming.duration("1:02:03"), 3723)
    }
    func testMissingZeroAndInvalidLengthsUseThreeMinutes() {
        for value in [nil, "", "0", "0:00", "-15", "3:75", "NaN", "inf", "1::3", "one", "1:2:3:4"] as [String?] {
            XCTAssertEqual(ChartScrollTiming.duration(value), 180, "\(value ?? "nil")")
        }
    }
    func testReachesBottomAtSongLengthRegardlessOfTickSizeOrChartHeight() {
        for distance in [400.0, 3000.0] {
            var position = 0.0
            for _ in 0..<720 {
                position = ChartScrollTiming.advance(position: position, distance: distance, elapsed: 0.25, duration: 180)
            }
            XCTAssertEqual(position, distance, accuracy: 0.001)
        }
    }
    func testPauseResumeKeepsSpeedAndNeverOvershoots() {
        XCTAssertEqual(ChartScrollTiming.advance(position: 500, distance: 1000, elapsed: 45, duration: 180), 750)
        XCTAssertEqual(ChartScrollTiming.advance(position: 990, distance: 1000, elapsed: 50, duration: 180), 1000)
        XCTAssertEqual(ChartScrollTiming.advance(position: 500, distance: 1000, elapsed: 0, duration: 180), 500)
        XCTAssertEqual(ChartScrollTiming.advance(position: 0, distance: 0, elapsed: 1, duration: 180), 0)
    }
}
