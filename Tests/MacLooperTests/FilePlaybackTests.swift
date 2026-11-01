import XCTest
import AVFoundation
@testable import MacLooper

final class FilePlaybackTests: XCTestCase {
    private var folder: URL!
    private var audio: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        audio = folder.appendingPathComponent("Silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: audio, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        pcm.frameLength = 4800
        for ch in 0..<2 { pcm.floatChannelData![ch].initialize(repeating: 0, count: 4800) }
        try file.write(from: pcm)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func testLoadDoesNotAutoplayAndSeekingClampsAndStopRewinds() async throws {
        let player = FilePlayback(), token = UUID()
        let loaded = try await player.load(audio, session: token, volume: 0, repeating: false)
        XCTAssertEqual(loaded.duration, 0.1, accuracy: 0.001)
        XCTAssertFalse(loaded.playing)
        await player.seek(session: token, to: 100)
        let end = await player.snapshot(session: token)!
        XCTAssertEqual(end.position, 0.1, accuracy: 0.001)
        await player.seek(session: token, to: -4)
        let start = await player.snapshot(session: token)!
        XCTAssertEqual(start.position, 0, accuracy: 0.001)
        await player.seek(session: token, to: 0.05)
        await player.stop(session: token)
        let stopped = await player.snapshot(session: token)!
        XCTAssertEqual(stopped.position, 0, accuracy: 0.001)
        XCTAssertFalse(stopped.playing)
        await player.unload()
    }
    @MainActor func testRestartRewindsWithoutChangingSelectionOrAutoplaying() async throws {
        let model = AudioFilePlayerModel(restoreFolder: false)
        defer { model.shutdown() }
        model.selectFile(audio)
        for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.error)
        model.seek(0.05)
        model.restart()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.position, 0, accuracy: 0.001)
        XCTAssertEqual(model.selected?.url, audio)
        XCTAssertFalse(model.playing)
    }
    func testStaleSessionCannotSeekOrStopNewSelection() async throws {
        let player = FilePlayback(), old = UUID(), current = UUID()
        _ = try await player.load(audio, session: old, volume: 0, repeating: false)
        _ = try await player.load(audio, session: current, volume: 0, repeating: true)
        await player.seek(session: current, to: 0.05)
        await player.seek(session: old, to: 0.08)
        await player.stop(session: old)
        await player.unload(session: old)
        let stale = await player.snapshot(session: old)
        let now = await player.snapshot(session: current)!
        XCTAssertNil(stale)
        XCTAssertEqual(now.position, 0.05, accuracy: 0.001)
        await player.unload()
    }
    func testUnreadableAudioReplacesPriorFileAndReportsAnError() async throws {
        let player = FilePlayback(), old = UUID(), current = UUID()
        _ = try await player.load(audio, session: old, volume: 0, repeating: false)
        let bad = folder.appendingPathComponent("Not audio.wav")
        try Data("not audio".utf8).write(to: bad)
        do { _ = try await player.load(bad, session: current, volume: 0, repeating: false); XCTFail("Should reject invalid audio") }
        catch { }
        let previous = await player.snapshot(session: old), failed = await player.snapshot(session: current)
        XCTAssertNil(previous); XCTAssertNil(failed)
    }
    func testDisconnectedOutputCannotFallBackToSystemSpeakers() async throws {
        let player = FilePlayback(), token = UUID()
        _ = try await player.load(audio, session: token, volume: 0, repeating: false)
        let missing = AudioDevice(id: 0, uid: "missing", name: "Missing", inputs: 0, outputs: 2, rate: 48000)
        do { try await player.play(session: token, output: missing); XCTFail("Should reject disconnected output") }
        catch { }
        let snapshot = await player.snapshot(session: token)!
        XCTAssertFalse(snapshot.playing)
        await player.unload()
    }
}
