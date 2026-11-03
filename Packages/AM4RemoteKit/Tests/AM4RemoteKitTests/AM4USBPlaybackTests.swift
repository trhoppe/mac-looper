import XCTest
@testable import AM4RemoteKit

final class AM4USBPlaybackTests: XCTestCase {
    private let initial = AM4USBPlaybackLevel(decibels: 0, text: "0.00 dB")
    private func reply(_ text: String, action: UInt8 = 13, parameter: UInt8 = 99) -> AM4Message {
        // Deliberately unrelated numeric fields: firmware display text is the
        // authoritative global dB read, not an Amp-normalization assumption.
        let raw: [UInt8] = [0xFF,0x7F,0x65,0x78,0,0,0,0x3F] + Array(text.utf8) + [UInt8](repeating: 0, count: 32-text.utf8.count)
        return AM4Message(bytes: AM4Message.request(function: 1,
            payload: [1,0,parameter,0,action,0,0,0,40,0] + AM4Message.pack(raw)))!
    }
    func testRequestTargetsGlobalUSBPlaybackNotPresetOrAmp() {
        let message = AM4Message(bytes: AM4Message.usbPlaybackRequest)!
        XCTAssertEqual(message.payload, [1,0,99,0,13,0,0,0,0,0])
    }
    func testReadUsesSignedDBDisplayAndRejectsWrongAddress() {
        XCTAssertEqual(reply("-12.00 dB").usbPlaybackLevel?.decibels, -12)
        XCTAssertEqual(reply("+1.11 dB").usbPlaybackLevel?.decibels, 1.11)
        XCTAssertEqual(reply("20.0").usbPlaybackLevel?.decibels, 20)
        XCTAssertEqual(reply("−∞ dB").usbPlaybackLevel?.decibels, -40)
        XCTAssertNil(reply("0.00 dB", parameter: 100).usbPlaybackLevel)
        XCTAssertNil(reply("0.00 dB", action: 1).usbPlaybackLevel)
    }
    func testInvalidAndOutOfRangeReadsAreNotUsed() {
        for text in ["nan dB", "inf dB", "21.00 dB", "-41 dB", "hello", "1.0 dB garbage", "1\n2"] {
            XCTAssertNil(reply(text).usbPlaybackLevel, text)
        }
    }
    func testAbsoluteDBWriteMatchesCapturedUSBPayload() {
        let command = AM4USBPlaybackCommand(expected: initial, decibels: 1.11)
        let message = AM4Message(bytes: AM4Message.usbPlaybackWrite(command)!)!
        XCTAssertEqual(Array(message.payload.prefix(10)), [1,0,99,0,1,0,0,0,4,0])
        // AM4-Edit capture: displayed 1.11 dB → this packed absolute Float32.
        XCTAssertEqual(Array(message.payload.dropFirst(10)), [0x3D,0x45,0x11,0x63,0x78])
        let negative = AM4USBPlaybackCommand(expected: initial, decibels: -12)
        let raw = AM4Message.unpack(Array(AM4Message(bytes: AM4Message.usbPlaybackWrite(negative)!)!.payload.dropFirst(10)), count: 4)!
        let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[$1]) << ($1 * 8) }
        XCTAssertEqual(Float(bitPattern: bits), -12)
    }
    func testRangeMatchesDeviceCacheAndManual() {
        for target in [-40.0, 0, 20] { XCTAssertTrue(AM4USBPlaybackCommand(expected: initial, decibels: target).isValid) }
        for target in [Double.nan, .infinity, -.infinity, -40.1, 20.1, 24] {
            XCTAssertNil(AM4Message.usbPlaybackWrite(AM4USBPlaybackCommand(expected: initial, decibels: target)))
        }
    }
    func testVerificationAndStaleValueComparison() {
        let command = AM4USBPlaybackCommand(expected: initial, decibels: -6)
        XCTAssertTrue(command.isConfirmed(by: AM4USBPlaybackLevel(decibels: -6, text: "-6.00 dB")))
        XCTAssertFalse(command.isConfirmed(by: initial))
        XCTAssertFalse(initial.matches(AM4USBPlaybackLevel(decibels: 1, text: "1.00 dB")))
    }
    func testGlobalStateHasNoPresetOrSceneDependency() throws {
        let first = AM4DeviceState(version: 9, status: "Connected", connected: true, loadingPresets: false,
                                   location: 96, snapshot: nil, presets: [], usbPlayback: initial)
        let other = AM4DeviceState(version: 9, status: "Connected", connected: true, loadingPresets: false,
                                   location: 13, snapshot: nil, presets: [], usbPlayback: initial)
        XCTAssertTrue(first.isValid); XCTAssertTrue(other.isValid)
        let decoded = try JSONDecoder().decode(AM4DeviceState.self, from: JSONEncoder().encode(other))
        XCTAssertEqual(decoded.usbPlayback, initial)
        XCTAssertTrue(AM4USBPlaybackCommand(expected: decoded.usbPlayback!, decibels: -3).isValid)
    }
}
