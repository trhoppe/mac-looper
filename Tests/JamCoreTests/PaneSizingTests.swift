import XCTest
@testable import JamCore

final class PaneSizingTests: XCTestCase {
    func testLeadingAndTrailingPreferencesAllocateExactAvailableSpace() {
        let a = PaneSizing.resolve(total: 1200, preferred: 280, side: .leading, minimumLeading: 220, minimumTrailing: 320, divider: 8)
        XCTAssertEqual(a.leading, 280); XCTAssertEqual(a.trailing, 912)
        let b = PaneSizing.resolve(total: 1200, preferred: 400, side: .trailing, minimumLeading: 300, minimumTrailing: 320, divider: 8)
        XCTAssertEqual(b.leading, 792); XCTAssertEqual(b.trailing, 400)
        XCTAssertEqual(b.primary(.trailing), 400)
    }
    func testDragLimitsKeepBothPanesUsable() {
        let wide = PaneSizing.resolve(total: 1000, preferred: 5000, side: .leading, minimumLeading: 220, minimumTrailing: 320, divider: 8)
        XCTAssertEqual(wide.leading, 672); XCTAssertEqual(wide.trailing, 320)
        let thin = PaneSizing.resolve(total: 1000, preferred: -500, side: .leading, minimumLeading: 220, minimumTrailing: 320, divider: 8)
        XCTAssertEqual(thin.leading, 220); XCTAssertEqual(thin.trailing, 772)
    }
    func testSmallerWindowClampsWithoutChangingSavedSizeAndLargerWindowRestoresIt() {
        let saved = 400.0
        let portrait = PaneSizing.resolve(total: 500, preferred: saved, side: .trailing, minimumLeading: 300, minimumTrailing: 320, divider: 16)
        XCTAssertGreaterThan(portrait.leading, 0); XCTAssertGreaterThan(portrait.trailing, 0)
        XCTAssertEqual(portrait.leading + portrait.trailing + portrait.divider, 500, accuracy: 0.0001)
        let landscape = PaneSizing.resolve(total: 1200, preferred: saved, side: .trailing, minimumLeading: 300, minimumTrailing: 320, divider: 16)
        XCTAssertEqual(landscape.trailing, saved)
    }
    func testInvalidOrTinyBoundsNeverProduceNegativeOrNonfiniteFrames() {
        for total in [0.0, 4, -1, .nan, .infinity] {
            let sizes = PaneSizing.resolve(total: total, preferred: .nan, side: .leading, minimumLeading: 220, minimumTrailing: 320, divider: 8)
            XCTAssertTrue(sizes.leading.isFinite && sizes.trailing.isFinite && sizes.divider.isFinite)
            XCTAssertGreaterThanOrEqual(sizes.leading, 0); XCTAssertGreaterThanOrEqual(sizes.trailing, 0)
        }
    }
}
