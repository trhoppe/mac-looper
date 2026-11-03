import XCTest
@testable import AM4RemoteKit

final class AM4AmpControlsTests: XCTestCase {
    private let catalog = AM4AmpCatalog.shared
    private func value(_ raw: UInt32, _ normalized: Double = 0, _ text: String = "OFF") -> AM4ParameterValue {
        AM4ParameterValue(raw: raw, normalized: normalized, text: text)
    }
    private var context: AM4AmpContext { AM4AmpContext(location: 96, scene: 0, blocks: [58, 118, 66, 70]) }
    private func frame(key: String, raw: UInt32, normalized: Float, text: String) -> AM4Message {
        let definition = catalog.definition(key)!
        let data: [UInt8] = [raw, normalized.bitPattern].flatMap { word in
            (0..<4).map { UInt8((word >> ($0 * 8)) & 255) }
        } + Array(text.utf8) + [UInt8](repeating: 0, count: 32 - text.utf8.count)
        return AM4Message(bytes: AM4Message.parameterFrame(definition, action: 13, raw: data))!
    }
    func testLiveMarshallLongReadIsValueAndDisplayText() {
        let bytes: [UInt8] = [0xF0,0xD2,0,0,0xA6,0xF1,0x52,0x3F] + Array("8.24".utf8) + [UInt8](repeating: 0, count: 28)
        let definition = catalog.definition("58:11")!
        let message = AM4Message(bytes: AM4Message.parameterFrame(definition, action: 13, raw: bytes))!
        let decoded = message.parameterValue(definition)!
        XCTAssertEqual(decoded.raw, 54000)
        XCTAssertEqual(decoded.normalized, 0.824, accuracy: 0.0001)
        XCTAssertEqual(decoded.text, "8.24")
        XCTAssertNil(message.parameterValue(catalog.definition("58:12")!))
    }
    func testContinuousAndEnumUseDifferentReadFields() {
        let model = frame(key: "58:10", raw: 207, normalized: 0.828, text: "Plexi 50W 6CA7 Jumped")
            .parameterValue(catalog.definition("58:10")!)!
        XCTAssertEqual(model.raw, 207)
        XCTAssertEqual(model.text, "Plexi 50W 6CA7 Jumped")
        let level = frame(key: "58:0", raw: 44563, normalized: 0.68, text: "-12.0 dB")
            .parameterValue(catalog.definition("58:0")!)!
        XCTAssertEqual(catalog.definition("58:0")!.displayValue(level.normalized), -12, accuracy: 0.001)
        XCTAssertEqual(catalog.definition("58:79")!.displayValue(0.5), 1000, accuracy: 0.001)
        XCTAssertEqual(catalog.definition("58:20")!.displayValue(0), 10, accuracy: 0.001)
    }
    func testSpeakerCurveUsesStableTableIDRatherThanReadOrdinal() {
        let definition = catalog.definition("58:135")!
        let decoded = frame(key: "58:135", raw: 36, normalized: 87, text: "4x12 5153 Stealth")
            .parameterValue(definition)!
        XCTAssertEqual(definition.ordinal(decoded), 87)
        XCTAssertEqual(definition.choices[87], decoded.text)
        let edit = AM4AmpEdit(context: context, model: 207, page: "Speaker", key: definition.key,
                              expected: decoded, ordinal: 88)
        XCTAssertTrue(edit.isValid)
        XCTAssertTrue(edit.isConfirmed(by: value(37, 88, "new curve")))
        XCTAssertFalse(edit.isConfirmed(by: value(88, 36, "wrong curve")))
        XCTAssertNil(frame(key: "58:135", raw: 36, normalized: 999, text: "invalid").parameterValue(definition))
    }
    func testMalformedLiveValuesAreRejected() {
        let definition = catalog.definition("58:11")!
        XCTAssertNil(frame(key: "58:11", raw: 0, normalized: .nan, text: "bad").parameterValue(definition))
        XCTAssertNil(frame(key: "58:11", raw: 0, normalized: 1.1, text: "bad").parameterValue(definition))
        XCTAssertNil(frame(key: "58:11", raw: 0, normalized: 0.5, text: "bad\ntext").parameterValue(definition))
        let wrongAction = AM4Message(bytes: AM4Message.parameterFrame(definition, action: 1, raw: [UInt8](repeating: 0, count: 40)))!
        XCTAssertNil(wrongAction.parameterValue(definition))
    }
    func testMarshallDumbleAndTweedHaveDifferentFrontPanels() {
        func labels(_ model: UInt32) -> [String] {
            catalog.controls(page: "Amp", values: ["58:10": value(model)]).map(\.label)
        }
        let marshall = labels(207), dumble = labels(110), tweed = labels(7)
        XCTAssertTrue(marshall.contains("Normal\nGain"))
        XCTAssertFalse(marshall.contains("Overdrive"))
        XCTAssertTrue(dumble.contains("Overdrive"))
        XCTAssertTrue(dumble.contains("Switches"))
        XCTAssertFalse(dumble.contains("Normal\nGain"))
        XCTAssertEqual(tweed, ["Gain", "Level", "Bypass"])
    }
    func testEveryModelResolvesWithoutDuplicateOrMissingControls() {
        for model in catalog.models.indices {
            let values = Dictionary(uniqueKeysWithValues: catalog.parameters.map {
                ($0.key, value($0.key == "58:10" ? UInt32(model) : 0))
            })
            for page in catalog.pages {
                let controls = catalog.controls(page: page.id, values: values)
                XCTAssertEqual(controls.count, Set(controls.map(\.key)).count)
                for control in controls {
                    XCTAssertNotNil(catalog.definition(control.key))
                    for condition in control.conditions { XCTAssertNotNil(catalog.definition(condition.key)) }
                }
            }
            let front = catalog.controls(page: "Amp", values: values)
            XCTAssertTrue(front.contains { $0.label.contains("Gain") })
            XCTAssertTrue(front.contains { $0.key == "58:0" })
            if [147, 210, 238, 239, 240].contains(model) {
                XCTAssertTrue(front.contains { $0.key == "58:81" && $0.label == "Gain" })
            }
        }
    }
    func testOnlyVisibleGEQVariantIsReturned() {
        let eqDefinition = catalog.parameters.first { $0.symbol == "DISTORT_EQTYPE" }!
        let values = ["58:10": value(207), eqDefinition.key: value(0)]
        let first = catalog.controls(page: "GEQ", values: values)
        XCTAssertFalse(first.isEmpty)
        let other = catalog.controls(page: "GEQ", values: ["58:10": value(207), eqDefinition.key: value(2)])
        XCTAssertNotEqual(first.map(\.label), other.map(\.label))
    }
    func testContinuousWriteDelegatesScalingToFirmware() {
        let edit = AM4AmpEdit(context: context, model: 207, page: "Amp", key: "58:11",
                              expected: value(54000, 0.824, "8.24"), normalized: 0.85)
        XCTAssertTrue(edit.isValid)
        let message = AM4Message(bytes: AM4Message.parameterWrite(edit)!)!
        XCTAssertEqual(Array(message.payload.prefix(10)), [58,0,11,0,2,0,0,0,4,0])
        let raw = AM4Message.unpack(Array(message.payload.dropFirst(10)), count: 4)!
        let bits = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(raw[$1]) << ($1 * 8)) }
        XCTAssertEqual(Float(bitPattern: bits), 0.85)
    }
    func testDynamicOptionsUseFirmwareNudgesInsteadOfCachedRoster() {
        let definition = catalog.definition("58:148")!
        XCTAssertTrue(definition.dynamic)
        let edit = AM4AmpEdit(context: context, model: 110, page: "Amp", key: definition.key,
                              expected: value(0), direction: 1)
        XCTAssertTrue(edit.isValid)
        XCTAssertEqual(AM4Message(bytes: AM4Message.parameterWrite(edit)!)!.payload,
                       [58,0,20,1,3,0,0,0,0,0])
        var wrong = edit
        wrong.direction = nil; wrong.ordinal = 1
        XCTAssertFalse(wrong.isValid)
        wrong.ordinal = nil; wrong.direction = 2
        XCTAssertFalse(wrong.isValid)
    }
    func testModelSelectionAndInvalidCommandsCannotWrite() {
        var edit = AM4AmpEdit(context: context, model: 207, page: "Amp", key: "58:11",
                              expected: value(0), normalized: 1.01)
        XCTAssertNil(AM4Message.parameterWrite(edit))
        edit.normalized = .nan
        XCTAssertFalse(edit.isValid)
        edit.normalized = 0.5; edit.ordinal = 1
        XCTAssertFalse(edit.isValid)
        let modelEdit = AM4AmpEdit(context: context, model: 207, page: "Amp", key: "58:10",
                                   expected: value(207), ordinal: 110)
        XCTAssertNil(AM4Message.parameterWrite(modelEdit))
        let otherPage = AM4AmpEdit(context: context, model: 207, page: "Speaker", key: "58:11",
                                   expected: value(0), normalized: 0.5)
        XCTAssertFalse(otherPage.isValid)
    }
    func testPackRoundTripAndDisplayNamesAreNotAssumedToBeOrdinals() {
        let data = Array(UInt8.min...UInt8.max)
        XCTAssertEqual(AM4Message.unpack(AM4Message.pack(data), count: 256), data)
        XCTAssertFalse(value(0, 0, "OFF").matches(value(0, 0, "Vintage")))
    }
}
