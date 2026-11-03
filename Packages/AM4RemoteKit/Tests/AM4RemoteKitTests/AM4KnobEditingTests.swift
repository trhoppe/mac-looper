import XCTest
@testable import AM4RemoteKit

final class AM4KnobEditingTests: XCTestCase {
    private let catalog = AM4AmpCatalog.shared
    private var context: AM4AmpContext { AM4AmpContext(location: 96, scene: 0, blocks: [58,118,70,66]) }
    private let current = AM4ParameterValue(raw: 65534, normalized: 1, text: "10.00")

    func testResetMatchesCapturedEditorDoubleClick() {
        let edit = AM4AmpEdit(context: context, model: 207, page: "Amp", key: "58:11", expected: current, resetToDefault: true)
        XCTAssertEqual(AM4Message.parameterWrite(edit),
                       [0xF0,0,1,0x74,0x15,1,0x3A,0,11,0,8,0,0,0,4,0,0,0,0,0,0,0x2C,0xF7])
        XCTAssertTrue(edit.isValid)
        XCTAssertFalse(edit.isConfirmed(by: current)) // no reset acknowledgement
        let defaultValue = AM4ParameterValue(raw: 32767, normalized: 0.5, text: "5.00")
        XCTAssertTrue(edit.isConfirmed(by: defaultValue, resetResult: defaultValue))
        XCTAssertFalse(edit.isConfirmed(by: current, resetResult: defaultValue))
        var combined = edit; combined.normalized = 0.5
        XCTAssertFalse(combined.isValid)
    }
    func testResetReplyAndLiveReadIgnoreUninitializedUpperPositionBytes() {
        let definition = catalog.definition("58:11")!
        let reset: [UInt8] = [0xF0,0,1,0x74,0x15,1,0x3A,0,11,0,8,0,0,0,0x28,0,
            0x7F,0x5F,0x60,0,0,0,0,0,0x1F,0x4D,0x25,0x63,1,0x40] + [UInt8](repeating: 0, count: 32) + [0x15,0xF7]
        let reply = AM4Message(bytes: reset)!.parameterValue(definition, action: 8)!
        XCTAssertEqual(reply.text, "5.00")
        XCTAssertEqual(reply.normalized, 0.5)
        var data: [UInt8] = [0xFF,0x7F,0x65,0x78,0,0,0,0x3F] + Array("5.00".utf8)
        data += [UInt8](repeating: 0, count: 28)
        let live = AM4Message(bytes: AM4Message.parameterFrame(definition, action: 13, raw: data))!.parameterValue(definition)!
        XCTAssertEqual(live.raw, 32767)
        XCTAssertTrue(live.matches(reply))
        XCTAssertNil(AM4Message(bytes: reset)!.parameterValue(definition))
    }
    func testTypedValuesUseDisplayUnitsForLinearAndLogarithmicControls() {
        let gain = catalog.definition("58:11")!
        XCTAssertEqual(gain.normalizedValue(forDisplay: 8.5)!, 0.85, accuracy: 0.00001)
        let level = catalog.definition("58:0")!
        XCTAssertEqual(level.normalizedValue(forDisplay: -12)!, 0.68, accuracy: 0.00001)
        let frequency = catalog.definition("58:79")!
        XCTAssertEqual(frequency.normalizedValue(forDisplay: 1000)!, 0.5, accuracy: 0.00001)
        let cap = catalog.definition("58:20")!
        XCTAssertEqual(cap.normalizedValue(forDisplay: 10)!, 0, accuracy: 0.00001)
        XCTAssertEqual(cap.normalizedValue(forDisplay: 10000)!, 1, accuracy: 0.00001)
    }
    func testTypingRejectsInvalidNumbersAndRoundsToParameterStep() {
        let gain = catalog.definition("58:11")!
        for value in [Double.nan, .infinity, -.infinity, -0.01, 10.01] { XCTAssertNil(gain.normalizedValue(forDisplay: value)) }
        XCTAssertEqual(gain.displayValue(gain.normalizedValue(forDisplay: 4.004)!), 4, accuracy: 0.000001)
        XCTAssertNil(catalog.definition("58:10")!.normalizedValue(forDisplay: 1))
    }
    func testDragStaysWithinKnobRange() {
        let gain = catalog.definition("58:11")!
        XCTAssertEqual(gain.position(afterDragging: 1000, from: 0.5), 1, accuracy: 0.00001)
        XCTAssertEqual(gain.position(afterDragging: -1000, from: 0.5), 0, accuracy: 0.00001)
        XCTAssertEqual(gain.position(afterDragging: 24, from: 0.5), 0.6, accuracy: 0.00001)
    }
}
