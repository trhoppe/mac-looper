import XCTest
import AVFoundation
import LooperAudioUnit
import JamCore
@testable import MacLooper

/// Explicit suspension, without timing-dependent sleeps or physical audio I/O.
@MainActor final class Suspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

final class AsyncReliabilityTests: XCTestCase {
    @MainActor private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
        XCTFail("Operation did not reach its checkpoint", file: file, line: line)
    }
    @MainActor func testPendingPlayIsInvalidatedBySelectionPauseStopAndUnload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = 48000
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 48000) }
            try file.write(from: buffer)
        }
        let asset = try PlaybackAsset(url)
        let output = AudioDevice(id: 0, uid: "offline", name: "Offline", inputs: 0, outputs: 2, rate: 48000)
        for command in ["select", "pause", "stop", "unload"] {
            let host = AudioEngineHost(playbackSetup: { engine in
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 32)
                return 48000
            })
            let old = UUID(), new = UUID()
            host.loadFile(asset, session: old, volume: 0, repeating: false)
            try await host.configuration.acquire()
            let task = Task { try await host.playFile(session: old, output: output) }
            // The queued Play cannot mutate the graph until we release ownership.
            await until { host.configuration.waitingCount == 1 }
            switch command {
            case "select": host.loadFile(asset, session: new, volume: 0, repeating: false)
            case "pause": host.pauseFile(session: old)
            case "stop": host.stopFile(session: old)
            default: host.unloadFile(session: old)
            }
            host.configuration.release()
            try await task.value
            XCTAssertFalse(host.isRunning, command)
            XCTAssertFalse(host.fileSnapshot(session: command == "select" ? new : old)?.playing ?? false, command)
            host.shutdown()
        }
        let host = AudioEngineHost()
        let token = UUID()
        host.loadFile(asset, session: token, volume: 0, repeating: false)
        let intent = try XCTUnwrap(host.requestFilePlay(session: token))
        host.stopFile(session: token)
        try await host.playFile(session: token, output: output, requestedIntent: intent)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(host.fileSnapshot(session: token)!.playing)
        host.shutdown()
    }
    @MainActor func testCancelledConfigurationWaiterPassesOwnershipToNextOperation() async throws {
        let gate = AudioConfigurationGate()
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        await until { gate.waitingCount == 1 }
        cancelled.cancel(); gate.release()
        do { try await cancelled.value; XCTFail("Cancelled owner must not proceed") } catch is CancellationError { }
        try await gate.acquire(); gate.release()
    }
    @MainActor func testLibrarySwitchDrainsLatestFolderAndRejectsStaleBackingLinks() async throws {
        let old = URL(fileURLWithPath: "/tmp/Old"), middle = URL(fileURLWithPath: "/tmp/Middle"), latest = URL(fileURLWithPath: "/tmp/New")
        let held = Suspension(); var reads: [String] = []
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = SongLibraryModel(defaults: defaults, loadOnLaunch: false, folderOverride: old, readLibrary: { url in
            let name = url.deletingLastPathComponent().lastPathComponent
            reads.append(name)
            return try JustChordsLibrary(data: Data("{\"songs\":[{\"id\":\"same\",\"title\":\"\(name)\",\"rawData\":\"Test\"}],\"playlists\":[]}".utf8))
        }, readTracks: { folder in
            if folder == old { await held.wait() }
            return ["same": folder.appendingPathComponent("track.mp3")]
        })
        defer { model.shutdown() }
        let task = Task { await model.refresh() }
        await until { held.entered }
        model.setFolder(middle)
        await Task.yield()
        model.setFolder(latest)
        await Task.yield()
        XCTAssertNil(model.library)
        XCTAssertNil(model.backingURL(songID: "same"))
        held.resume()
        await task.value
        await model.refresh()
        XCTAssertEqual(model.library?.songs.first?.title, "New")
        XCTAssertEqual(model.backingURL(songID: "same"), latest.appendingPathComponent("track.mp3"))
        XCTAssertNil(model.selectedSongID)
        XCTAssertTrue(reads.contains("New"))
    }
    @MainActor func testMissingNewLibraryNeverDisplaysOldLibraryAsNew() async throws {
        let held = Suspension(); var count = 0
        let model = SongLibraryModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, loadOnLaunch: false,
            folderOverride: URL(fileURLWithPath: "/tmp/Old"), readLibrary: { _ in
                count += 1
                if count == 1 { await held.wait(); return try JustChordsLibrary(data: Data(#"{"songs":[{"id":"a","title":"Old","rawData":"Test"}],"playlists":[]}"#.utf8)) }
                throw CocoaError(.fileReadNoSuchFile)
            })
        defer { model.shutdown() }
        let task = Task { await model.refresh() }
        await until { held.entered }
        model.setFolder(URL(fileURLWithPath: "/tmp/Missing"))
        await Task.yield(); held.resume(); await task.value; await model.refresh()
        XCTAssertNil(model.library); XCTAssertNotNil(model.error)
    }
}

extension AsyncReliabilityTests {
    @MainActor func testSelectionDuringGraphSetupCannotAutoplayOrReceiveStaleError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = 48000
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 48000) }
            try file.write(from: buffer)
        }
        let asset = try PlaybackAsset(url)
        let output = AudioDevice(id: 0, uid: "offline", name: "Offline", inputs: 0, outputs: 2, rate: 48000)
        for fail in [false, true] {
            let held = Suspension()
            let drums = PopDrummerModel(instrumentLoader: { AVAudioUnitSampler() })
            await drums.prepare()
            let host = AudioEngineHost(drums: drums, playbackSetup: { engine in
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 32)
                return 48000
            }, makeGain: {
                await held.wait()
                if fail { throw AudioFailure(message: "Old graph setup failed") }
                return try await AudioEngineHost.makeDrummerGain()
            })
            defer { host.shutdown() }
            let old = UUID(), new = UUID()
            host.loadFile(asset, session: old, volume: 0, repeating: false)
            let play = Task { try await host.playFile(session: old, output: output) }
            await until { held.entered }
            host.loadFile(asset, session: new, volume: 0, repeating: false)
            held.resume(); try await play.value
            XCTAssertFalse(host.fileSnapshot(session: new)!.playing)
            XCTAssertEqual(host.fileSnapshot(session: new)!.position, 0)
            XCTAssertNil(host.fileSnapshot(session: old))
        }
    }
    @MainActor func testRefreshDefersPublishingUntilEditorCloses() async throws {
        let held = Suspension(); var title = "Original"
        let model = SongLibraryModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, loadOnLaunch: false,
            folderOverride: URL(fileURLWithPath: "/tmp/Own"), readLibrary: { _ in
                if title == "Updated" { await held.wait() }
                return try JustChordsLibrary(data: Data("{\"songs\":[{\"id\":\"a\",\"title\":\"\(title)\",\"rawData\":\"Test\"}],\"playlists\":[]}".utf8))
            }, readTracks: { _ in [:] })
        defer { model.shutdown() }
        await model.refresh(); title = "Updated"
        let task = Task { await model.refresh() }
        await until { held.entered }
        model.editing = true; held.resume(); await task.value
        XCTAssertEqual(model.library?.songs.first?.title, "Original")
        title = "After editor"
        model.editing = false
        await model.refresh()
        XCTAssertEqual(model.library?.songs.first?.title, "After editor")
    }
}
