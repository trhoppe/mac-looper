import XCTest
import AVFoundation
import AudioToolbox
import LooperCore
import LooperAudioUnit

final class LoopAudioUnitTests: XCTestCase {
    private func unit() throws -> MLGuitarLoopAudioUnit {
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6D6C6C70,
                                         componentManufacturer: 0x4D614C70, componentFlags: 0, componentFlagsMask: 0)
        let u = try MLGuitarLoopAudioUnit(componentDescription: d, options: [])
        u.require32Frames = true
        try u.allocateRenderResources()
        return u
    }
    private func render(_ unit: MLGuitarLoopAudioUnit, frames: UInt32 = 32, input: Float = 0.5) -> [Float] {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: Int(frames)), right = UnsafeMutablePointer<Float>.allocate(capacity: Int(frames))
        left.initialize(repeating: 0, count: Int(frames)); right.initialize(repeating: 0, count: Int(frames))
        defer { left.deallocate(); right.deallocate() }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let pointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.initialize(to: AudioBufferList(mNumberBuffers: 2, mBuffers: AudioBuffer()))
        let list = UnsafeMutableAudioBufferListPointer(pointer)
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: left)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: right)
        var flags: AudioUnitRenderActionFlags = [], time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        let status = unit.internalRenderBlock(&flags, &time, frames, 0, list.unsafeMutablePointer, nil) { _, _, n, _, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            for buffer in buffers {
                buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: input, count: Int(n))
            }
            return noErr
        }
        XCTAssertEqual(status, 0)
        return Array(UnsafeBufferPointer(start: left, count: Int(frames)))
    }
    func testAudioUnitNeverMonitorsAndCapturesAnExactLoop() throws {
        let u = try unit(); defer { u.deallocateRenderResources() }
        XCTAssertTrue(render(u).allSatisfy { $0 == 0 })
        let core = try XCTUnwrap(u.core)
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_ARM), 4096))
        for _ in 0..<120 { XCTAssertTrue(render(u).allSatisfy { $0 == 0 }) }
        _ = render(u)
        XCTAssertEqual(tl_snapshot(core).state, Int32(TL_PLAYING))
        XCTAssertEqual(tl_snapshot(core).recorded, 4096)
        for _ in 0..<16 { _ = render(u) }
        XCTAssertTrue(render(u).contains { $0 > 0 })
        XCTAssertEqual(u.callbackFrames, 32)
    }
    func testIPadPolicyAcceptsActualQuantumAndKeepsExactCaptureLength() throws {
        let u = try unit(); defer { u.deallocateRenderResources() }
        u.require32Frames = false
        let core = try XCTUnwrap(u.core)
        XCTAssertTrue(render(u, frames: 128).allSatisfy { $0 == 0 })
        XCTAssertTrue(tl_command(core, Int32(TL_CMD_ARM), 4096))
        for _ in 0..<40 { _ = render(u, frames: 128) }
        XCTAssertEqual(u.callbackFrames, 128); XCTAssertEqual(u.renderError, 0)
        XCTAssertEqual(tl_snapshot(core).state, Int32(TL_PLAYING))
        XCTAssertEqual(tl_snapshot(core).recorded, 4096)
    }
    func testStrictBufferPolicySilencesUnexpectedQuantum() throws {
        let u = try unit(); defer { u.deallocateRenderResources() }
        XCTAssertTrue(render(u, frames: 64).allSatisfy { $0 == 0 })
        XCTAssertEqual(u.renderError, Int32(TL_BUFFER_SIZE_ERROR))
        XCTAssertEqual(tl_snapshot(u.core).state, Int32(TL_EMPTY))
    }
}
