import XCTest
@testable import AM4RemoteKit

final class AM4NavigationTests: XCTestCase {
    func testPresetIndicesUseFloatWhileScenesUseIntegers() {
        let preset = AM4NavigationCommand(preset: 1, expectedLocation: 96)
        let scene = AM4NavigationCommand(scene: 1, expectedLocation: 96)
        let p = AM4Message(bytes: AM4Message.navigationWrite(preset)!)!
        let s = AM4Message(bytes: AM4Message.navigationWrite(scene)!)!
        XCTAssertEqual(Array(p.payload.prefix(10)), [78,1,10,0,1,0,0,0,4,0])
        XCTAssertEqual(Array(s.payload.prefix(10)), [78,1,13,0,1,0,0,0,4,0])
        XCTAssertEqual(Array(p.payload.dropFirst(10)), [0,0,16,3,120]) // Float32(1)
        XCTAssertEqual(Array(s.payload.dropFirst(10)), [0,64,0,0,0]) // UInt32(1)
        XCTAssertEqual(AM4Message.unpack(Array(p.payload.dropFirst(10)), count: 4), [0,0,128,63])
        XCTAssertEqual(AM4Message.unpack(Array(s.payload.dropFirst(10)), count: 4), [1,0,0,0])
    }
    func testEveryPresetAndSceneIsAddressable() {
        for index in 0..<104 {
            let command = AM4NavigationCommand(preset: index, expectedLocation: 96)
            let message = AM4Message(bytes: AM4Message.navigationWrite(command)!)!
            let raw = AM4Message.unpack(Array(message.payload.dropFirst(10)), count: 4)!
            let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[$1]) << ($1 * 8) }
            XCTAssertEqual(Float(bitPattern: bits), Float(index))
        }
        for index in 0..<4 {
            let command = AM4NavigationCommand(scene: index, expectedLocation: 96)
            let message = AM4Message(bytes: AM4Message.navigationWrite(command)!)!
            XCTAssertEqual(AM4Message.unpack(Array(message.payload.dropFirst(10)), count: 4), [UInt8(index),0,0,0])
        }
    }
    func testSceneConfirmationIsScopedToItsOriginalPreset() {
        let command = AM4NavigationCommand(scene: 2, expectedLocation: 96)
        XCTAssertTrue(command.isConfirmed(location: 96, scene: 2))
        XCTAssertFalse(command.isConfirmed(location: 97, scene: 2))
        XCTAssertFalse(command.isConfirmed(location: 96, scene: 1))
    }
    func testPresetConfirmationUsesLocationRatherThanCurrentScene() {
        let command = AM4NavigationCommand(preset: 97, expectedLocation: 96)
        XCTAssertTrue(command.isConfirmed(location: 97, scene: 0))
        XCTAssertTrue(command.isConfirmed(location: 97, scene: 3))
        XCTAssertFalse(command.isConfirmed(location: 96, scene: 0))
    }
    func testInvalidAndAmbiguousTargetsCannotWrite() {
        for command in [
            AM4NavigationCommand(preset: -1, expectedLocation: 96),
            AM4NavigationCommand(preset: 104, expectedLocation: 96),
            AM4NavigationCommand(scene: -1, expectedLocation: 96),
            AM4NavigationCommand(scene: 4, expectedLocation: 96),
            AM4NavigationCommand(scene: 1, expectedLocation: 104),
            AM4NavigationCommand(preset: 1, scene: 1, expectedLocation: 96),
            AM4NavigationCommand(expectedLocation: 96)
        ] {
            XCTAssertFalse(command.isValid)
            XCTAssertNil(AM4Message.navigationWrite(command))
            XCTAssertFalse(command.isConfirmed(location: 96, scene: 1))
        }
    }
}
