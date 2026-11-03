import XCTest
@testable import AM4RemoteKit

final class AM4PresetSavingTests: XCTestCase {
    private func state(edited: Bool? = true, scene: Int = 0, name: String = "Test") -> AM4Snapshot {
        AM4Snapshot(name: name, scene: scene, sceneNames: ["Clean", "Drive", "", ""], blockIDs: [58, 66, 70, 0], edited: edited)
    }
    func testSaveFrameUsesIntegerSlotAndRejectsInvalidAddress() throws {
        let command = AM4PresetSaveCommand(location: 103, snapshot: state())
        let frame = try XCTUnwrap(AM4Message.savePresetWrite(command))
        XCTAssertEqual(Array(frame.dropLast(2)), [0xF0, 0, 1, 0x74, 0x15, 1, 0, 0, 0, 0, 0x1B, 0, 0, 0, 4, 0, 0x33, 0x40, 0, 0, 0])
        XCTAssertEqual(AM4Message(bytes: frame)?.function, 1)
        for location in [-1, 104] { XCTAssertNil(AM4Message.savePresetWrite(AM4PresetSaveCommand(location: location, snapshot: state()))) }
        XCTAssertNil(AM4Message.savePresetWrite(AM4PresetSaveCommand(location: 0, snapshot: state(scene: 4))))
        let ack = AM4Message.request(function: 1, payload: [0, 0, 0, 0, 0x1B, 0, 0, 0, 0, 0])
        XCTAssertTrue(try XCTUnwrap(AM4Message(bytes: ack)).acknowledgesPresetSave)
        XCTAssertFalse(try XCTUnwrap(AM4Message(bytes: frame)).acknowledgesPresetSave, "A reflected write cannot verify a permanent save")
        XCTAssertFalse(try XCTUnwrap(AM4Message(bytes: AM4Message.snapshotRequest)).acknowledgesPresetSave)
        var corrupt = ack; corrupt[corrupt.count - 2] ^= 1; XCTAssertNil(AM4Message(bytes: corrupt))
    }
    func testEditedBitIsReadFromValidatedPatchDescriptor() throws {
        var payload: [UInt8] = [78, 1, 0, 0, 31, 0, 0, 0, 64, 1] + AM4Message.pack(Array(repeating: 0, count: 192))
        XCTAssertEqual(AM4Message(bytes: AM4Message.request(function: 1, payload: payload))?.snapshot?.edited, false)
        payload[15] |= 4
        XCTAssertEqual(AM4Message(bytes: AM4Message.request(function: 1, payload: payload))?.snapshot?.edited, true)
        payload[0] = 0
        XCTAssertNil(AM4Message(bytes: AM4Message.request(function: 1, payload: payload))?.snapshot, "Wrong descriptor address must not publish a dirty state")
    }
    func testReadGlobalLevelAndNavigationDoNotMarkPresetEdited() throws {
        for frame in [AM4Message.snapshotRequest, AM4Message.locationRequest, AM4Message.ampGainRequest,
                      AM4Message.storedPresetNameRequest(103)!, AM4Message.savePresetWrite(AM4PresetSaveCommand(location: 103, snapshot: state()))!,
                      AM4Message.navigationWrite(AM4NavigationCommand(preset: 1, expectedLocation: 0))!,
                      AM4Message.request(function: 1, payload: [1, 0, 99, 0, 1, 0, 0, 0, 4, 0] + AM4Message.pack([0, 0, 0, 0]))] {
            XCTAssertFalse(try XCTUnwrap(AM4Message(bytes: frame)).editsPreset)
        }
        XCTAssertTrue(try XCTUnwrap(AM4Message(bytes: AM4Message.ampGainWrite(2)!)).editsPreset)
        XCTAssertTrue(try XCTUnwrap(AM4Message(bytes: AM4Message.navigationWrite(AM4NavigationCommand(scene: 1, expectedLocation: 0))!)).editsPreset)
        XCTAssertTrue(try XCTUnwrap(AM4Message(bytes: AM4Message.request(function: 0x75, payload: [0]))).editsPreset)
    }
    @MainActor func testSaveCommitsOnceThenRequiresCleanReadAndMatchingStoredName() async throws {
        let command = AM4PresetSaveCommand(location: 103, snapshot: state())
        var commits = 0, reads = 0
        let result = try await AM4PresetSaveOperation.run(command, requireEdited: true,
            readLocation: { 103 }, readSnapshot: { reads += 1; return self.state(edited: commits == 0) },
            commit: { commits += 1 }, readStoredName: { "Test" }, sessionIsCurrent: { true }, wait: {})
        XCTAssertEqual(result, .saved); XCTAssertEqual(commits, 1); XCTAssertEqual(reads, 2)
    }
    @MainActor func testStalePresetSceneOrSessionAndUnsettledBitNeverCommit() async throws {
        let command = AM4PresetSaveCommand(location: 103, snapshot: state())
        for scenario in 0..<5 {
            var commits = 0
            do {
                _ = try await AM4PresetSaveOperation.run(command, requireEdited: true,
                    readLocation: { scenario == 0 ? 102 : 103 },
                    readSnapshot: { self.state(edited: scenario == 3 ? nil : scenario != 2, scene: scenario == 1 ? 1 : 0) },
                    commit: { commits += 1 }, readStoredName: { "Test" }, sessionIsCurrent: { scenario != 4 }, wait: {})
                XCTFail("Must refuse stale or unverified state")
            } catch { }
            XCTAssertEqual(commits, 0)
        }
    }
    @MainActor func testAlreadyCleanSkipsPermanentWrite() async throws {
        var commits = 0
        let result = try await AM4PresetSaveOperation.run(AM4PresetSaveCommand(location: 0, snapshot: state()), requireEdited: false,
            readLocation: { 0 }, readSnapshot: { self.state(edited: false) }, commit: { commits += 1 },
            readStoredName: { "Test" }, sessionIsCurrent: { true }, wait: {})
        XCTAssertEqual(result, .alreadyClean); XCTAssertEqual(commits, 0)
    }
    @MainActor func testMissingAckUnclearedFlagWrongNameAndChangedContextNeverClaimSuccessOrRetry() async throws {
        let command = AM4PresetSaveCommand(location: 103, snapshot: state())
        for scenario in 0..<4 {
            var commits = 0
            do {
                _ = try await AM4PresetSaveOperation.run(command, requireEdited: true,
                    readLocation: { 103 }, readSnapshot: { self.state(edited: commits == 0 || scenario == 1, scene: commits > 0 && scenario == 3 ? 1 : 0) },
                    commit: { commits += 1; if scenario == 0 { throw AM4PresetSaveOperation.Failure(message: "No acknowledgement") } },
                    readStoredName: { scenario == 2 ? "Wrong" : "Test" }, sessionIsCurrent: { true }, wait: {})
                XCTFail("Must not claim success")
            } catch { }
            XCTAssertEqual(commits, 1, "A permanent write must never be automatically retried")
        }
    }
    @MainActor func testDisconnectedSaveReportsWhyAndCannotWrite() async throws {
        let connection = AM4Connection()
        XCTAssertFalse(connection.canSavePreset)
        do { try await connection.savePreset(AM4PresetSaveCommand(location: 0, snapshot: state())); XCTFail("Disconnected") } catch { }
        XCTAssertFalse(connection.isSavingPreset); XCTAssertFalse(connection.hasUnsavedPresetChanges)
        XCTAssertFalse(connection.presetSaveStatus.isEmpty)
        connection.stop()
    }
}
