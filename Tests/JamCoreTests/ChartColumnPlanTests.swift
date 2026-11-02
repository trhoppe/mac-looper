import XCTest
@testable import JamCore

final class ChartColumnPlanTests: XCTestCase {
    func testColumnsFollowAvailableWidthAndFontSize() {
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 800, fontSize: 24), 800)
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 800, fontSize: 14), 386)
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 1100, fontSize: 24), 536)
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 400, fontSize: 12), 400)
    }
    func testBalancedReadingOrderWithUnevenMeasuredBlocks() {
        let heights = [20.0, 30, 70, 20, 20, 80]
        let split = ChartColumnPlan.split(heights: heights, breaks: Array(repeating: .normal, count: 6), availableWidth: 1100, fontSize: 18)
        XCTAssertEqual(split, 3)
        XCTAssertEqual(Array(heights[..<split!]) + Array(heights[split!...]), heights)
    }
    func testHeadingStaysWithItsLyricsEvenWhenHalfway() {
        XCTAssertEqual(ChartColumnPlan.split(heights: [90, 20, 80], breaks: [.normal, .section, .normal], availableWidth: 1100, fontSize: 18), 1)
    }
    func testBlankAfterHeadingCannotOrphanIt() {
        XCTAssertEqual(ChartColumnPlan.split(heights: [80, 20, 10, 60], breaks: [.normal, .section, .blank, .normal], availableWidth: 1100, fontSize: 18), 1)
    }
    func testPreferNearbySectionBoundaryAndAvoidLeadingBlank() {
        let breaks: [ChartColumnPlan.Break] = [.normal, .normal, .blank, .section, .normal, .normal, .normal]
        XCTAssertEqual(ChartColumnPlan.split(heights: [40, 40, 8, 20, 40, 40, 40], breaks: breaks, availableWidth: 1100, fontSize: 18), 3)
    }
    func testNarrowEmptyAndHeadingOnlyChartsStaySingleColumn() {
        XCTAssertNil(ChartColumnPlan.split(heights: [30, 30], breaks: [.normal, .normal], availableWidth: 400, fontSize: 18))
        XCTAssertNil(ChartColumnPlan.split(heights: [], breaks: [], availableWidth: 1100, fontSize: 18))
        XCTAssertNil(ChartColumnPlan.split(heights: [30], breaks: [.normal], availableWidth: 1100, fontSize: 18))
        XCTAssertNil(ChartColumnPlan.split(heights: [20, 30], breaks: [.section, .normal], availableWidth: 1100, fontSize: 18))
    }
}
