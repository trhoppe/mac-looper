import XCTest
@testable import AM4RemoteKit

final class AM4ProtocolTests: XCTestCase {
    func testAmpGainWriteMatchesCapturedFloatPacking() {
        let captured = "F0 00 01 74 15 01 3A 00 0B 00 01 00 00 00 04 00 66 73 19 43 68 02 F7"
            .split(separator: " ").map { UInt8($0, radix: 16)! }
        XCTAssertEqual(AM4Message.ampGainWrite(1), captured)
        XCTAssertNotNil(AM4Message.ampGainWrite(0))
        XCTAssertNotNil(AM4Message.ampGainWrite(10))
        for invalid in [-0.01, 10.01, .infinity, -.infinity, .nan] {
            XCTAssertNil(AM4Message.ampGainWrite(invalid))
        }
    }

    func testAmpGainReadUsesFixedPointRatherThanFloatWriteFormat() throws {
        let response = AM4Message.request(function: 1, payload:
            [0x3A, 0, 0x0B, 0, 0x0E, 0, 0, 0, 4, 0, 0x66, 0x13, 0, 0, 0])
        let value = try XCTUnwrap(AM4Message(bytes: response)?.ampGain)
        XCTAssertEqual(value, 3, accuracy: 0.0002)
        XCTAssertNil(AM4Message(bytes: AM4Message.ampGainWrite(3)!)?.ampGain)
    }

    func testAmpGainReadRejectsBadAddressAndOutOfRange() {
        for header in [[UInt8(0x3A), 0, 0x0C, 0, 0x0E, 0, 0, 0, 4, 0],
                       [0x3A, 0, 0x0B, 0, 1, 0, 0, 0, 4, 0]] {
            XCTAssertNil(AM4Message(bytes: AM4Message.request(function: 1,
                payload: header + [0x66, 0x13, 0, 0, 0]))?.ampGain)
        }
        // 0x0000FFFF is outside the supported 0..65534 read range.
        XCTAssertNil(AM4Message(bytes: AM4Message.request(function: 1,
            payload: [0x3A, 0, 0x0B, 0, 0x0E, 0, 0, 0, 4, 0, 0x7F, 0x7F, 0x60, 0, 0]))?.ampGain)
    }

    func testGainCommandRejectsStalePresetSceneAndGain() {
        let original = AM4AmpState(context: AM4AmpContext(location: 98, scene: 0,
            blocks: [0x76, 0x3A, 0x46, 0x42]), gain: 3)
        XCTAssertTrue(AM4GainCommand(expected: original, gain: 4).isValid)
        XCTAssertTrue(original.matches(original))
        XCTAssertFalse(AM4AmpState(context: original.context, gain: 4).matches(original))
        let other = AM4AmpState(context: AM4AmpContext(location: 99, scene: 0,
            blocks: original.context.blocks), gain: 3)
        XCTAssertFalse(other.matches(original))
        let scene = AM4AmpState(context: AM4AmpContext(location: 98, scene: 1,
            blocks: original.context.blocks), gain: 3)
        XCTAssertFalse(scene.matches(original))
        XCTAssertFalse(AM4GainCommand(expected: original, gain: .nan).isValid)
        XCTAssertFalse(AM4GainCommand(expected: original, gain: 11).isValid)
        XCTAssertFalse(AM4AmpContext(location: 98, scene: 0, blocks: [0, 0, 0, 0]).isValid)
    }

    func testHelperAmpStateMustMatchCurrentSnapshot() throws {
        let snapshot = try XCTUnwrap(AM4Message(bytes: fixture(scene: 2))?.snapshot)
        let amp = AM4AmpState(context: AM4AmpContext(location: 98, scene: 2,
            blocks: snapshot.blockIDs), gain: 3)
        let valid = AM4DeviceState(version: 9, status: "Connected", connected: true,
            loadingPresets: false, location: 98, snapshot: snapshot, presets: [], amp: amp)
        XCTAssertTrue(valid.isValid)
        XCTAssertTrue(try JSONDecoder().decode(AM4DeviceState.self,
            from: JSONEncoder().encode(valid)).isValid)
        let stale = AM4DeviceState(version: 9, status: "Connected", connected: true,
            loadingPresets: false, location: 99, snapshot: snapshot, presets: [], amp: amp)
        XCTAssertFalse(stale.isValid)
    }

    func testCapturedStoredNameRequests() {
        let prefix: [UInt8] = [0xF0, 0, 1, 0x74, 0x15, 1, 0x4E, 1, 0x0B, 0, 0x12, 0, 0, 0, 4, 0]
        XCTAssertEqual(AM4Message.storedPresetNameRequest(0), prefix + [0, 0, 0, 0, 0, 0x43, 0xF7])
        XCTAssertEqual(AM4Message.storedPresetNameRequest(1), prefix + [0, 0x40, 0, 0, 0, 3, 0xF7])
        XCTAssertEqual(AM4Message.storedPresetNameRequest(103), prefix + [0x33, 0x40, 0, 0, 0, 0x30, 0xF7])
        XCTAssertNil(AM4Message.storedPresetNameRequest(-1))
        XCTAssertNil(AM4Message.storedPresetNameRequest(104))
    }

    func testCapturedEmptyStoredName() throws {
        let bytes = "F0 00 01 74 15 01 4E 01 0B 00 12 00 00 00 20 00 1E 11 29 55 02 51 32 3E 00 08 04 02 01 00 40 20 10 08 04 02 01 00 40 20 10 08 04 02 01 00 40 20 10 08 04 00 00 38 F7"
            .split(separator: " ").map { UInt8($0, radix: 16)! }
        XCTAssertEqual(try XCTUnwrap(AM4Message(bytes: bytes)).storedPresetName, "<EMPTY>")
    }

    func testCatalogCorrelatesEverySlotAndIgnoresUnrelatedMessages() throws {
        var catalog = AM4PresetCatalog()
        XCTAssertEqual(catalog.start(), AM4Message.storedPresetNameRequest(0))
        let unrelated = try XCTUnwrap(AM4Message(bytes: AM4Message.firmwareRequest))
        XCTAssertNil(catalog.receive(unrelated))
        XCTAssertEqual(catalog.pendingLocation, 0)
        for index in 0..<104 {
            let name = index == 103 ? "<EMPTY>" : "Preset \(index)"
            let next = catalog.receive(try XCTUnwrap(AM4Message(bytes: nameFixture(name))))
            XCTAssertEqual(catalog.presets.last?.id, index)
            XCTAssertEqual(catalog.presets.last?.name, name)
            XCTAssertEqual(next, index < 103 ? AM4Message.storedPresetNameRequest(index + 1) : nil)
        }
        XCTAssertTrue(catalog.isComplete)
        XCTAssertNil(catalog.pendingLocation)
        XCTAssertTrue(catalog.presets.last!.isEmpty)
    }

    func testCanceledCatalogDoesNotMislabelALateReply() throws {
        var catalog = AM4PresetCatalog()
        _ = catalog.start()
        catalog.cancel()
        XCTAssertNil(catalog.receive(try XCTUnwrap(AM4Message(bytes: nameFixture("Late reply")))))
        XCTAssertTrue(catalog.presets.isEmpty)
    }

    func testNameDecoderRejectsWrongHeaderAndTruncation() {
        var bytes = nameFixture("Stored name")
        bytes[10] = 0x0C // rename action is not a name read
        bytes[bytes.count - 2] = AM4Message.checksum(Array(bytes.dropLast(2)))
        XCTAssertNil(AM4Message(bytes: bytes)?.storedPresetName)
        XCTAssertNil(AM4Message(bytes: AM4Message.snapshotRequest)?.storedPresetName)
        XCTAssertNil(AM4Message(bytes: Array(nameFixture("Name").dropLast()))?.storedPresetName)
    }

    func testHelperStateRejectsDuplicateAndOutOfBoundsSlots() throws {
        let presets = [AM4Preset(id: 0, name: "Real preset")]
        let state = AM4DeviceState(version: 9, status: "Connected", connected: true,
                                   loadingPresets: false, location: 0, snapshot: nil, presets: presets)
        XCTAssertTrue(try JSONDecoder().decode(AM4DeviceState.self, from: JSONEncoder().encode(state)).isValid)
        for invalid in [[presets[0], presets[0]], [AM4Preset(id: 104, name: "Bad slot")]] {
            XCTAssertFalse(AM4DeviceState(version: 9, status: "", connected: true,
                                          loadingPresets: false, location: nil, snapshot: nil,
                                          presets: invalid).isValid)
        }
    }

    func testCapturedNameTableRequest() {
        XCTAssertEqual(AM4Message.snapshotRequest, [
            0xF0, 0, 1, 0x74, 0x15, 1, 0x4E, 1, 0, 0,
            0x1F, 0, 0, 0, 0, 0, 0x41, 0xF7
        ])
    }

    func testCapturedSceneModeChecksum() {
        XCTAssertEqual(AM4Message.request(function: 0x12, payload: [0x49]),
                       [0xF0, 0, 1, 0x74, 0x15, 0x12, 0x49, 0x4B, 0xF7])
    }

    func testRejectsCorruptionAndOtherDeviceModels() {
        let valid = AM4Message.firmwareRequest
        for index in 0..<valid.count {
            var corrupted = valid
            corrupted[index] ^= 1
            XCTAssertNil(AM4Message(bytes: corrupted), "Byte \(index)")
        }
        XCTAssertNil(AM4Message(bytes: []))
    }

    func testSplitFramesAndRealtimeInterleaving() {
        var stream = SysExStream()
        let frame = AM4Message.request(function: 1, payload:
            [0x4E, 1, 0x0A, 0, 0x0E, 0, 0, 0, 4, 0, 0x33, 0x40, 0, 0, 0])
        XCTAssertTrue(stream.receive([0x90, 60, 127] + frame.prefix(4)).isEmpty)
        let messages = stream.receive([0xF8] + frame.dropFirst(4) + frame)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.location, 103)
    }

    func testRecoversFromInterruptedAndOversizedFrames() {
        var stream = SysExStream()
        XCTAssertTrue(stream.receive([0xF0, 1, 0x90, 2, 0xF7]).isEmpty)
        XCTAssertTrue(stream.receive([0xF0] + Array(repeating: 0, count: 70_000)).isEmpty)
        XCTAssertEqual(stream.receive(AM4Message.firmwareRequest).count, 1)
    }

    func testLocationRangeAndLabels() {
        XCTAssertEqual(AM4Message.locationLabel(0), "A1")
        XCTAssertEqual(AM4Message.locationLabel(103), "Z4")
        XCTAssertEqual(AM4Message.locationLabel(-1), "—")
        XCTAssertNil(AM4Message(bytes: AM4Message.request(function: 0x14, payload: [104, 0]))?.location)
        XCTAssertEqual(AM4Message.locationLabel(98), "Y3")
        // Do not mark A1 current based on the legacy reply that returned
        // zero on the user's AM4 while Y3 was actually active.
        XCTAssertNil(AM4Message(bytes: AM4Message.request(function: 0x14, payload: [0, 0]))?.location)
    }

    func testCurrentLocationUsesThePatchRegister() throws {
        let header: [UInt8] = [0x4E, 1, 0x0A, 0, 0x0E, 0, 0, 0, 4, 0]
        let y3 = AM4Message.request(function: 1, payload: header + [0x31, 0, 0, 0, 0])
        XCTAssertEqual(try XCTUnwrap(AM4Message(bytes: y3)).location, 98)
        let invalid = AM4Message.request(function: 1, payload: header + [0x34, 0, 0, 0, 0])
        XCTAssertNil(AM4Message(bytes: invalid)?.location)
        XCTAssertEqual(AM4Message.locationRequest,
                       AM4Message.request(function: 1, payload: [0x4E, 1, 0x0A, 0, 0x0E, 0, 0, 0, 0, 0]))
    }

    func testCapturedContinuousBitstream() {
        XCTAssertEqual(AM4Message.unpack([0x66, 0x73, 0x19, 0x43, 0x68], count: 4),
                       [0xCD, 0xCC, 0xCC, 0x3D]) // float32 0.1
        XCTAssertNil(AM4Message.unpack([0x80], count: 0))
        XCTAssertNil(AM4Message.unpack([0x01], count: 0))
    }

    func testSnapshotNamesSceneAndLoadedBlocks() throws {
        let message = try XCTUnwrap(AM4Message(bytes: fixture(scene: 2)))
        let state = try XCTUnwrap(message.snapshot)
        XCTAssertEqual(state.name, "Evening Clean")
        XCTAssertEqual(state.scene, 2)
        XCTAssertEqual(state.sceneNames, ["Clean", "Edge", "Lead", "Ambient"])
        XCTAssertEqual(state.blockIDs, [0x76, 0x3A, 0x46, 0x42])
    }

    func testRejectsInvalidSceneAndTruncatedTable() {
        XCTAssertNil(AM4Message(bytes: fixture(scene: 4))?.snapshot)
        XCTAssertNil(AM4Message(bytes: AM4Message.request(function: 1, payload: [0]))?.snapshot)
    }

    private func fixture(scene: UInt8) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 192)
        raw[8] = scene
        for (offset, name) in [(16, "Evening Clean"), (48, "Clean"), (80, "Edge"),
                               (112, "Lead"), (144, "Ambient")] {
            raw.replaceSubrange(offset..<(offset + name.utf8.count), with: name.utf8)
        }
        for (index, block) in [UInt8(0x76), 0x3A, 0x46, 0x42].enumerated() {
            raw[176 + index * 4] = block
        }
        // Independent bit-array fixture encoder to exercise byte boundaries.
        var bits = raw.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
        while bits.count % 7 != 0 { bits.append(0) }
        let packed = stride(from: 0, to: bits.count, by: 7).map { start in
            bits[start..<(start + 7)].reduce(UInt8(0)) { ($0 << 1) | $1 }
        }
        return AM4Message.request(function: 1, payload:
            [0x4E, 1, 0, 0, 0x1F, 0, 0, 0, 0x40, 1] + packed)
    }

    private func nameFixture(_ name: String) -> [UInt8] {
        var raw = Array(name.utf8) + [0]
        raw += Array(repeating: 0x20, count: 32 - raw.count)
        var bits = raw.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
        while bits.count % 7 != 0 { bits.append(0) }
        let packed = stride(from: 0, to: bits.count, by: 7).map { start in
            bits[start..<(start + 7)].reduce(UInt8(0)) { ($0 << 1) | $1 }
        }
        return AM4Message.request(function: 1, payload:
            [0x4E, 1, 0x0B, 0, 0x12, 0, 0, 0, 0x20, 0] + packed)
    }
}
