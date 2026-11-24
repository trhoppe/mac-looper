import XCTest
import AVFoundation
import LooperCore
import LooperAudioUnit
import JamCore
@testable import MacLooper

final class SavedLoopHostTests: XCTestCase {
    @MainActor func testFileOpenIntentWaitsForStartupAndProtectsUnsavedTake() async throws {
        let model = LooperModel()
        defer { model.shutdown() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jamloop")
        defer { try? FileManager.default.removeItem(at: url) }
        let loop = try SavedLoop(sampleRate: 48000, bpm: 90, bars: 1, left: Array(repeating: 0.2, count: 32), right: Array(repeating: 0.1, count: 32))
        try loop.encoded().write(to: url)
        model.state = Int32(TL_STOPPED); model.starting = true
        let opening = Task { await model.openLoop(url) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.pendingRecall)
        model.starting = false
        await opening.value
        XCTAssertEqual(model.pendingRecall?.loop.bpm, 90)
        XCTAssertEqual(model.state, Int32(TL_STOPPED))
        XCTAssertFalse(model.acceptsMIDI)
        model.pendingRecall = nil
        XCTAssertTrue(model.acceptsMIDI)
    }
    func testSampleRateConversionKeepsDurationAndStereoPolarity() throws {
        for sourceRate in [44100.0, 48000.0, 96000.0] {
            let frames = 1501
            let samples = (0..<frames).map { Float(sin(Double($0) * 2 * .pi * 220 / sourceRate)) * 0.3 }
            let loop = try SavedLoop(sampleRate: sourceRate, bpm: 123, bars: 4, left: samples, right: samples.map { -$0 })
            for rate in [44100.0, 48000.0, 96000.0] {
                let audio = try LoopAudioTransfer.resampled(loop, rate: rate)
                XCTAssertEqual(Double(audio.left.count) / rate, loop.duration, accuracy: 1 / rate)
                XCTAssertEqual(audio.left.count, audio.right.count)
                for index in stride(from: 100, to: audio.left.count - 100, by: 101) {
                    XCTAssertEqual(audio.left[index], -audio.right[index], accuracy: 0.00001)
                }
            }
        }
    }
    @MainActor func testOutputOnlyRecallSaveAndReRecallKeepDrummerGraphAndClock() async throws {
        let drums = PopDrummerModel(instrumentLoader: { AVAudioUnitSampler() })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let host = AudioEngineHost(drums: drums, playbackSetup: { engine in
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
            return 48000
        })
        defer { host.shutdown() }
        let route = AudioDevice(id: 0, uid: "offline", name: "Offline", inputs: 0, outputs: 2, rate: 48000)
        let loop = try SavedLoop(sampleRate: 48000, bpm: 120, bars: 1, left: Array(repeating: 0.4, count: 96000), right: Array(repeating: -0.2, count: 96000))
        try await host.prepareLoopRecall(output: route)
        try await host.restoreLoop(loop)
        let engine = try XCTUnwrap(host.engine), core = try XCTUnwrap(host.core)
        XCTAssertFalse(host.captureEnabled)
        XCTAssertEqual(tl_snapshot(core).state, Int32(TL_STOPPED))
        await drums.prepare()
        try await host.attachPreparedDrummer(to: engine)
        try MLAudioGraphTools.prepare(engine)
        drums.setPlaying(true); host.updateDrummerVolume()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        func render(_ frames: UInt32 = 512) {
            var error: OSStatus = 0
            XCTAssertEqual(engine.manualRenderingBlock(frames, buffer.mutableAudioBufferList, &error), .success)
            XCTAssertEqual(error, 0)
        }
        for _ in 0..<17 { render() }
        let beat = drums.transport.beatPosition
        XCTAssertGreaterThan(beat, 0)
        let saved = try await host.snapshotLoop(bpm: 120, bars: 1)
        XCTAssertEqual(saved.leftPCM, loop.leftPCM); XCTAssertEqual(saved.rightPCM, loop.rightPCM)
        try await host.prepareLoopRecall(output: route); try await host.restoreLoop(saved)
        XCTAssertTrue(host.engine === engine); XCTAssertEqual(host.core, core)
        XCTAssertEqual(drums.transport.beatPosition, beat, accuracy: 1e-10)
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_PLAY_SYNC), 0))
        render(); XCTAssertEqual(tl_snapshot(core).state, Int32(TL_WAITING))
        // 96000 is the next beat 1 after starting drums. Render through it;
        // position proves frame-zero alignment, independently of seam fades.
        let remaining = 96000 - 18 * 512
        for _ in 0..<(remaining / 512) { render() }
        if remaining % 512 > 0 { render(UInt32(remaining % 512)) }
        XCTAssertEqual(tl_snapshot(core).position, 0)
        render(32)
        XCTAssertEqual(tl_snapshot(core).state, Int32(TL_PLAYING)); XCTAssertEqual(tl_snapshot(core).position, 32)
        XCTAssertEqual(drums.transport.beatPosition, 4 + 32.0 / 24000, accuracy: 1e-8)
    }
}
