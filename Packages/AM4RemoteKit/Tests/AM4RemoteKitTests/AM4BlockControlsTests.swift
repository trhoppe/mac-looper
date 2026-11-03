import XCTest
@testable import AM4RemoteKit

final class AM4BlockControlsTests: XCTestCase {
    private var context: AM4BlockContext { AM4BlockContext(location: 96, scene: 0, blocks: [58,118,70,0]) }
    private func state(_ bypassed: Bool, context: AM4BlockContext? = nil) -> AM4BlocksState {
        AM4BlocksState(context: context ?? self.context, blocks: [
            AM4BlockBypass(slot: 0, type: 58, bypassed: false),
            AM4BlockBypass(slot: 1, type: 118, bypassed: bypassed),
            AM4BlockBypass(slot: 2, type: 70, bypassed: false)])
    }
    func testDriveBypassAndEnableMatchCapturedEditorFrames() {
        let off = AM4BlockBypassCommand(context: context, slot: 1, type: 118, expectedBypassed: false, bypassed: true)
        let on = AM4BlockBypassCommand(context: context, slot: 1, type: 118, expectedBypassed: true, bypassed: false)
        XCTAssertEqual(AM4Message.blockBypassWrite(off), [0xF0,0,1,0x74,0x15,1,0x76,0,3,0,1,0,0,0,4,0,0,0,16,3,120,10,0xF7])
        XCTAssertEqual(AM4Message.blockBypassWrite(on), [0xF0,0,1,0x74,0x15,1,0x76,0,3,0,1,0,0,0,4,0,0,0,0,0,0,0x61,0xF7])
    }
    func testAmpBypassMatchesCapturedEditorCommand() {
        let command = AM4BlockBypassCommand(context: context, slot: 0, type: 58, expectedBypassed: false, bypassed: true)
        XCTAssertEqual(AM4Message.blockBypassWrite(command), [0xF0,0,1,0x74,0x15,1,0x3A,0,3,0,1,0,0,0,4,0,0,0,16,3,120,0x46,0xF7])
    }
    func testBypassReadsUseLiveBooleanAndRejectWriteEchoes() {
        let definition = AM4ParameterDefinition.bypass(block: 118)!
        for bypassed in [false,true] {
            let bits = Float(bypassed ? 1 : 0).bitPattern
            var raw = [UInt8(bypassed ? 1 : 0),0,0x65,0x78] + (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
            let text = Array((bypassed ? "BYPASSED" : "ENGAGED").utf8)
            raw += text + [UInt8](repeating: 0, count: 32-text.count)
            let message = AM4Message(bytes: AM4Message.parameterFrame(definition, action: 13, raw: raw))!
            XCTAssertEqual(message.blockBypass(118), bypassed)
            XCTAssertNil(message.blockBypass(58))
            let echo = AM4Message(bytes: AM4Message.parameterFrame(definition, action: 1, raw: raw))!
            XCTAssertNil(echo.blockBypass(118))
        }
    }
    func testBypassVerificationRequiresSamePresetSceneSlotAndType() {
        let command = AM4BlockBypassCommand(context: context, slot: 1, type: 118, expectedBypassed: false, bypassed: true)
        XCTAssertTrue(command.isConfirmed(by: state(true)))
        XCTAssertFalse(command.isConfirmed(by: state(false)))
        XCTAssertFalse(command.isConfirmed(by: state(true, context: AM4BlockContext(location: 97, scene: 0, blocks: context.blocks))))
        XCTAssertFalse(command.isConfirmed(by: state(true, context: AM4BlockContext(location: 96, scene: 1, blocks: context.blocks))))
    }
    func testEmptyMissingAndDuplicateSlotsAreRejected() {
        XCTAssertTrue(state(false).isValid)
        XCTAssertNil(state(false).block(slot: 3, type: 0))
        let command = AM4BlockBypassCommand(context: context, slot: 3, type: 0, expectedBypassed: false, bypassed: true)
        XCTAssertNil(AM4Message.blockBypassWrite(command))
        let duplicate = AM4BlocksState(context: context, blocks: [AM4BlockBypass(slot: 1,type: 118,bypassed: false),AM4BlockBypass(slot: 1,type: 118,bypassed: true),AM4BlockBypass(slot: 2,type: 70,bypassed: false)])
        XCTAssertFalse(duplicate.isValid)
        XCTAssertFalse(AM4BlocksState(context: context, blocks: []).isValid)
    }
    func testBypassWorksInPresetsWithoutAnAmpAndRejectsUnchangedTargets() {
        let noAmp = AM4BlockContext(location: 96, scene: 0, blocks: [118,70,0,0])
        let command = AM4BlockBypassCommand(context: noAmp, slot: 0, type: 118, expectedBypassed: false, bypassed: true)
        XCTAssertTrue(command.isValid)
        let same = AM4BlockBypassCommand(context: noAmp, slot: 0, type: 118, expectedBypassed: true, bypassed: true)
        XCTAssertFalse(same.isValid)
        XCTAssertNil(AM4Message.blockBypassWrite(same))
    }
    func testHelperStateRejectsBlockDataFromAnotherScene() throws {
        let snapshot = AM4Snapshot(name: "Marshall", scene: 0, sceneNames: ["One","Two","Three","Four"], blockIDs: context.blocks)
        let valid = AM4DeviceState(version: 9, status: "Connected", connected: true, loadingPresets: false,
                                    location: 96, snapshot: snapshot, presets: [], blocks: state(false))
        XCTAssertTrue(valid.isValid)
        let decoded = try JSONDecoder().decode(AM4DeviceState.self, from: JSONEncoder().encode(valid))
        XCTAssertEqual(decoded.blocks, state(false))
        let stale = AM4DeviceState(version: 9, status: "Connected", connected: true, loadingPresets: false,
                                    location: 96, snapshot: snapshot, presets: [],
                                    blocks: state(false, context: AM4BlockContext(location: 96, scene: 1, blocks: context.blocks)))
        XCTAssertFalse(stale.isValid)
    }

}
