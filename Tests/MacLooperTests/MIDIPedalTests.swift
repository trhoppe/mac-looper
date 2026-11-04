import XCTest
import CoreMIDI
import JamCore
@testable import MacLooper

@MainActor final class MIDIPedalTests: XCTestCase {
    func testVirtualControllerHotPlugLongPacketsReleasesAndDisconnect() async throws {
        let input = JamMIDIInput()
        var received: [JamMIDIAction] = []
        input.start { action in
            // Emulate an asynchronous audio startup: subsequent presses stay ordered.
            if action == .arm { try? await Task.sleep(for: .milliseconds(20)) }
            received.append(action)
        }
        defer { input.stop() }
        XCTAssertFalse(input.status.contains("unavailable"), input.status)
        var client: MIDIClientRef = 0, source: MIDIEndpointRef = 0
        XCTAssertEqual(MIDIClientCreateWithBlock("Mac Jams test controller" as CFString, &client, nil), noErr)
        defer { MIDIClientDispose(client) }
        let name = "Pedal test " + UUID().uuidString
        let sourceResult = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        #if os(iOS)
        if sourceResult == kMIDINotPermitted {
            throw XCTSkip("iPadOS permits the input listener but does not permit this test's virtual MIDI source. Hot-plug delivery is tested on macOS; physical iPad pedal verification remains separate.")
        }
        #endif
        XCTAssertEqual(sourceResult, noErr)
        defer { if source != 0 { MIDIEndpointDispose(source) } }
        for _ in 0..<100 where !input.status.contains(name) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(input.status.contains(name), input.status)

        let capacity = 8192
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        // Larger than the struct's fixed 64-word tuple, followed by a second packet.
        let words: [UInt32] = Array(repeating: 0x10F80000, count: 100) +
            (22...26).flatMap { [0x20B0007F | UInt32($0) << 8, 0x20B00000 | UInt32($0) << 8] }
        packet = try XCTUnwrap(words.withUnsafeBufferPointer { MIDIEventListAdd(list, capacity, packet, 1, $0.count, $0.baseAddress!) })
        let extra: [UInt32] = [0x2FBF1A01, 0x2FBF1A00] // CC26 on channel 16, group 16.
        _ = try XCTUnwrap(extra.withUnsafeBufferPointer { MIDIEventListAdd(list, capacity, packet, 2, $0.count, $0.baseAddress!) })
        XCTAssertEqual(list.pointee.numPackets, 2)
        XCTAssertEqual(MIDIReceivedEventList(source, list), noErr)
        for _ in 0..<100 where received.count < 6 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(received, [.arm, .record, .playStop, .clear, .drummer, .drummer])

        input.stop()
        XCTAssertEqual(MIDIReceivedEventList(source, list), noErr)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(received.count, 6, "Disposed input ports cannot deliver stale actions")
        input.start { received.append($0) }
        XCTAssertTrue(input.status.contains(name))
        MIDIEndpointDispose(source); source = 0
        for _ in 0..<100 where input.status.contains(name) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(input.status.contains(name), "Removed controllers must leave the connection list")
    }
}
