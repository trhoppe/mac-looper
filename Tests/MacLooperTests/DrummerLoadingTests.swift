import XCTest
import AVFoundation
import LooperCore
import LooperAudioUnit
@testable import MacLooper

final class DrummerLoadingTests: XCTestCase {
    @MainActor func testFailedPluginIsCachedUntilRetryOrRegistrationChange() async {
        var attempts = 0
        let model = PopDrummerModel(instrumentLoader: {
            attempts += 1; throw AudioFailure(message: "Missing test plugin")
        })
        await model.prepare(); await model.prepare(); await model.prepare()
        XCTAssertEqual(attempts, 1); XCTAssertFalse(model.ready); XCTAssertNotNil(model.error)
        await model.retry(); XCTAssertEqual(attempts, 2)
        model.componentsChanged(); await model.prepare(); XCTAssertEqual(attempts, 3)
    }
    @MainActor func testSlowPluginLoadIsSharedWithoutOwningAudioConfiguration() async throws {
        let held = Suspension(); var attempts = 0
        let drums = PopDrummerModel(instrumentLoader: {
            attempts += 1; await held.wait(); return AVAudioUnitSampler()
        })
        let host = AudioEngineHost(drums: drums)
        let first = Task { await drums.prepare() }
        for _ in 0..<1000 { if held.entered { break }; await Task.yield() }
        XCTAssertTrue(held.entered)
        let second = Task { await drums.prepare() }
        try await host.configuration.acquire()
        XCTAssertTrue(drums.loading); XCTAssertEqual(attempts, 1)
        host.configuration.release()
        held.resume(); await first.value; await second.value
        XCTAssertTrue(drums.ready); XCTAssertEqual(attempts, 1)
        host.shutdown()
    }
}

extension DrummerLoadingTests {
    @MainActor func testAttachingInstrumentPreservesCapturedLoopAndSuspendingDoesNotAutoplay() async throws {
        let drums = PopDrummerModel(instrumentLoader: { AVAudioUnitSampler() })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        input.frameLength = 32
        for ch in 0..<2 { input.floatChannelData![ch].initialize(repeating: 0.5, count: 32) }
        let host = AudioEngineHost(drums: drums, playbackSetup: { engine in
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 32)
            XCTAssertTrue(engine.inputNode.setManualRenderingInputPCMFormat(format) { _ in input.audioBufferList })
            return 48000
        })
        defer { host.shutdown() }
        let route = AudioDevice(id: 0, uid: "offline", name: "Offline", inputs: 2, outputs: 2, rate: 48000)
        try await host.startLoop(input: route, output: route, channel: 0)
        let engine = try XCTUnwrap(host.engine), core = try XCTUnwrap(host.core)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        output.frameLength = 32
        func render() {
            var error: OSStatus = 0
            XCTAssertEqual(engine.manualRenderingBlock(32, output.mutableAudioBufferList, &error), .success)
            XCTAssertEqual(error, 0)
        }
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_ARM), 512))
        for _ in 0..<64 { render() }
        XCTAssertEqual(tl_snapshot(core).state, Int32(TL_PLAYING))
        await drums.prepare()
        try await host.configuration.acquire()
        do {
            try await host.attachPreparedDrummer(to: engine)
            try MLAudioGraphTools.prepare(engine)
            host.configuration.release()
        } catch { host.configuration.release(); throw error }
        XCTAssertTrue(host.engine === engine)
        XCTAssertEqual(host.core, core)
        XCTAssertEqual(tl_snapshot(core).recorded, 512)
        for _ in 0..<64 { render() }
        XCTAssertEqual(tl_snapshot(core).state, Int32(TL_PLAYING))
        XCTAssertGreaterThan((0..<256).map { tl_waveform(core, UInt32($0)) }.max()!, 0.49)
        host.suspendAudio()
        XCTAssertEqual(tl_snapshot(core).state, Int32(TL_STOPPED))
        XCTAssertEqual(tl_snapshot(core).recorded, 512)
        let resumed = try await host.resumeSuspendedAudio()
        XCTAssertTrue(resumed)
        for _ in 0..<16 { render(); XCTAssertEqual(output.floatChannelData![0][16], 0) }
        XCTAssertEqual(tl_snapshot(core).state, Int32(TL_STOPPED))
    }
}
