import XCTest
import AVFoundation
import AudioToolbox
import LooperCore
import LooperAudioUnit

final class SharedGraphTests: XCTestCase {
    func testMixedBackingNeverEntersCaptureAndGraphRendersThirtyTwoFrames() async throws {
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6D6C6C70,
                                         componentManufacturer: 0x4D614C70, componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(MLGuitarLoopAudioUnit.self, as: d, name: "Mac Looper: Test", version: 1)
        let node: AVAudioUnit = try await withCheckedThrowingContinuation { c in
            AVAudioUnit.instantiate(with: d) { node, error in
                if let node { c.resume(returning: node) } else { c.resume(throwing: error!) }
            }
        }
        let unit = try XCTUnwrap(node.auAudioUnit as? MLGuitarLoopAudioUnit)
        unit.require32Frames = true
        let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        func constant(_ value: Float) -> AVAudioSourceNode {
            AVAudioSourceNode(format: format) { _, _, frames, list in
                for b in UnsafeMutableAudioBufferListPointer(list) {
                    b.mData!.assumingMemoryBound(to: Float.self).update(repeating: value, count: Int(frames))
                }
                return noErr
            }
        }
        let guitar = constant(0.5), backing = constant(0.125)
        engine.attach(guitar); engine.attach(backing); engine.attach(node)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 32)
        try MLAudioGraphTools.connect(engine, source: guitar, sourceBus: 0, destination: node, destinationBus: 0, format: format)
        try MLAudioGraphTools.connect(engine, source: node, sourceBus: 0, destination: engine.mainMixerNode, destinationBus: 0, format: format)
        try MLAudioGraphTools.connect(engine, source: backing, sourceBus: 0, destination: engine.mainMixerNode, destinationBus: 1, format: format)
        try MLAudioGraphTools.prepare(engine)
        try MLAudioGraphTools.start(engine)
        defer { engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        for _ in 0..<12 {
            XCTAssertEqual(try engine.renderOffline(32, to: buffer), .success)
            XCTAssertEqual(buffer.floatChannelData![0][16], 0.125, accuracy: 0.0001, "Only backing plays before arming; guitar is never monitored")
        }
        let core = try XCTUnwrap(unit.core)
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_ARM), 512))
        for _ in 0..<40 { XCTAssertEqual(try engine.renderOffline(32, to: buffer), .success) }
        let state = tl_snapshot(core)
        XCTAssertEqual(state.state, Int32(TL_PLAYING)); XCTAssertEqual(state.recorded, 512)
        XCTAssertEqual(unit.callbackFrames, 32); XCTAssertEqual(unit.renderError, 0)
        let peaks = (0..<256).map { tl_waveform(core, UInt32($0)) }
        XCTAssertEqual(peaks.max()!, 0.5, accuracy: 0.0001, "Backing is mixed after capture")
        XCTAssertTrue(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 32)).contains { $0 > 0.2 })
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_CLEAR), 0))
        for _ in 0..<12 { XCTAssertEqual(try engine.renderOffline(32, to: buffer), .success) }
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_RECORD), 1024))
        for _ in 0..<10 { XCTAssertEqual(try engine.renderOffline(32, to: buffer), .success) }
        XCTAssertEqual(tl_snapshot(core).recorded, 320, "Manual capture adds no history")
        XCTAssertEqual(buffer.floatChannelData![0][16], 0.125, accuracy: 0.0001, "Guitar still is not monitored")
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_RECORD), 1024))
        for _ in 0..<20 { XCTAssertEqual(try engine.renderOffline(32, to: buffer), .success) }
        XCTAssertEqual(tl_snapshot(core).length, 320)
        XCTAssertEqual(tl_snapshot(core).cycles, 2)
        XCTAssertEqual((0..<256).map { tl_waveform(core, UInt32($0)) }.max()!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(unit.callbackFrames, 32); XCTAssertEqual(unit.renderError, 0)
    }
}

#if os(macOS)
extension SharedGraphTests {
    func testManualRealtimeInputUsesAllInterfaceChannelsWithoutMonitoring() async throws {
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6D6C6C70,
                                         componentManufacturer: 0x4D614C70, componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(MLGuitarLoopAudioUnit.self, as: d, name: "Mac Looper: Test", version: 1)
        let node: AVAudioUnit = try await withCheckedThrowingContinuation { c in
            AVAudioUnit.instantiate(with: d) { node, error in
                if let node { c.resume(returning: node) } else { c.resume(throwing: error!) }
            }
        }
        let unit = try XCTUnwrap(node.auAudioUnit as? MLGuitarLoopAudioUnit)
        unit.require32Frames = true; unit.inputLeft = 2; unit.inputRight = 3
        let engine = AVAudioEngine()
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
        let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 32)!
        pcm.frameLength = 32
        for channel in 0..<4 { pcm.floatChannelData![channel].initialize(repeating: channel > 1 ? 0.5 : 0.1, count: 32) }
        try engine.enableManualRenderingMode(.realtime, format: stereo, maximumFrameCount: 32)
        XCTAssertTrue(engine.inputNode.setManualRenderingInputPCMFormat(input) { frames in
            frames == 32 ? pcm.audioBufferList : nil
        })
        engine.attach(node)
        try MLAudioGraphTools.connect(engine, source: engine.inputNode, sourceBus: 0, destination: node, destinationBus: 0, format: input)
        try MLAudioGraphTools.connect(engine, source: node, sourceBus: 0, destination: engine.mainMixerNode, destinationBus: 0, format: stereo)
        try MLAudioGraphTools.prepare(engine); try MLAudioGraphTools.start(engine)
        defer { engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 32)!
        output.frameLength = 32
        func render() {
            var error: OSStatus = 0
            XCTAssertEqual(engine.manualRenderingBlock(32, output.mutableAudioBufferList, &error), .success)
            XCTAssertEqual(error, 0)
        }
        for _ in 0..<12 { render(); XCTAssertEqual(output.floatChannelData![0][16], 0) }
        let core = try XCTUnwrap(unit.core)
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_ARM), 512))
        for _ in 0..<40 { render() }
        XCTAssertEqual(tl_snapshot(core).recorded, 512)
        XCTAssertEqual((0..<256).map { tl_waveform(core, UInt32($0)) }.max()!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(unit.callbackFrames, 32); XCTAssertEqual(unit.renderError, 0)
    }
}
#endif
