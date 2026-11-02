import XCTest
@testable import JamCore

final class ChartColumnPlanTests: XCTestCase {
    func testColumnsFollowAvailableWidthAndFontSize() {
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 800, fontSize: 24), 800)
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 800, fontSize: 14), 386)
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 1100, fontSize: 24), 536)
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 400, fontSize: 12), 400)
    }
    func testConsecutiveLinesReadAcrossRowsWithoutLosingOrReorderingContent() {
        let rows = ChartColumnPlan.rows(spanning: Array(repeating: false, count: 7), availableWidth: 1100, fontSize: 18)
        XCTAssertEqual(rows, [[0, 1], [2, 3], [4, 5], [6]])
        XCTAssertEqual(rows.flatMap { $0 }, Array(0..<7))
    }
    func testFullWidthTabFlushesOddLineAndStartsFreshPairAfterward() {
        XCTAssertEqual(ChartColumnPlan.rows(spanning: [false, true, false, false, false], availableWidth: 1100, fontSize: 18), [[0], [1], [2, 3], [4]])
    }
    func testSectionHeadingsAndBlankSeparatorsSpanRows() {
        XCTAssertEqual(ChartColumnPlan.rows(spanning: [true, false, false, true, true, false], availableWidth: 1100, fontSize: 18), [[0], [1, 2], [3], [4], [5]])
    }
    func testNarrowAndEmptyChartsKeepNaturalSingleColumnOrder() {
        XCTAssertEqual(ChartColumnPlan.rows(spanning: [false, false, true, false], availableWidth: 400, fontSize: 18), [[0], [1], [2], [3]])
        XCTAssertEqual(ChartColumnPlan.rows(spanning: [], availableWidth: 1100, fontSize: 18), [])
    }
}

extension ChartColumnPlanTests {
    func testOneColumnChoiceOverridesWideChartAndCanSwitchBack() {
        XCTAssertEqual(ChartColumnPlan.columnWidth(availableWidth: 1100, fontSize: 14, twoColumns: false), 1100)
        XCTAssertEqual(ChartColumnPlan.rows(spanning: [false, false, true, false, false], availableWidth: 1100, fontSize: 14, twoColumns: false), [[0], [1], [2], [3], [4]])
        XCTAssertEqual(ChartColumnPlan.rows(spanning: [false, false, true, false, false], availableWidth: 1100, fontSize: 14, twoColumns: true), [[0, 1], [2], [3, 4]])
    }
}
