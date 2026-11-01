import XCTest
import LooperCore

final class DSP {
    let core: OpaquePointer
    init(rate: Double = 48000, capacity: UInt32 = 100000) {
        core = tl_create(rate, capacity)!
        tl_set_threshold(core, 0.1)
        tl_set_volume(core, 1)
    }
    deinit { tl_destroy(core) }
    @discardableResult func render(_ l: [Float], _ r: [Float]? = nil) -> ([Float], [Float]) {
        let right = r ?? l
        precondition(right.count == l.count)
        var ol = [Float](repeating: 0, count: l.count), or = ol
        l.withUnsafeBufferPointer { lp in right.withUnsafeBufferPointer { rp in
            ol.withUnsafeMutableBufferPointer { op in or.withUnsafeMutableBufferPointer { oq in
                tl_process(core, lp.baseAddress, rp.baseAddress, op.baseAddress, oq.baseAddress, UInt32(l.count))
            } }
        } }
        return (ol, or)
    }
    @discardableResult func silence(_ n: Int) -> ([Float], [Float]) { render([Float](repeating: 0, count: n)) }
    var snapshot: TLSnapshot { tl_snapshot(core) }
    func arm(_ frames: UInt32 = 4800) { XCTAssertTrue(tl_command(core, Int32(TL_CMD_ARM), frames)) }
    func makeLoop() { arm(); render([Float](repeating: 0.5, count: 4560)); XCTAssertEqual(snapshot.state, Int32(TL_PLAYING)) }
}

final class LooperCoreTests: XCTestCase {
    func testBarDurationAtCommonAndFractionalTempos() {
        XCTAssertEqual(tl_loop_frames(48000, 120, 2, 4), 192000)
        XCTAssertEqual(tl_loop_frames(48000, 120, 4, 4), 384000)
        XCTAssertEqual(tl_loop_frames(48000, 30, 8, 4), 3072000)
        XCTAssertEqual(tl_loop_frames(44100, 137, 8, 4), UInt32((44100.0 * 60 / 137 * 32).rounded()))
        XCTAssertEqual(tl_loop_frames(96000, 93, 2, 4), UInt32((96000.0 * 60 / 93 * 8).rounded()))
    }
    func testInvalidTimingAndAllocationAreRejected() {
        XCTAssertEqual(tl_loop_frames(48000, 0, 4, 4), 0)
        XCTAssertEqual(tl_loop_frames(.nan, 120, 4, 4), 0)
        XCTAssertEqual(tl_loop_frames(48000, .infinity, 4, 4), 0)
        XCTAssertNil(tl_create(0, 100))
        XCTAssertNil(tl_create(48000, 0))
        let dsp = DSP()
        XCTAssertFalse(tl_command(dsp.core, Int32(TL_CMD_ARM), 100001))
        XCTAssertFalse(tl_command(dsp.core, Int32(TL_CMD_ARM), 0))
    }
    func testLiveInputIsNeverMonitoredInEmptyArmedOrRecordingStates() {
        let dsp = DSP()
        XCTAssertTrue(dsp.render([Float](repeating: 0.8, count: 512)).0.allSatisfy { $0 == 0 })
        dsp.arm()
        XCTAssertTrue(dsp.render([Float](repeating: 0.05, count: 512)).0.allSatisfy { $0 == 0 })
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_ARMED))
        XCTAssertTrue(dsp.render([Float](repeating: 0.7, count: 512)).0.allSatisfy { $0 == 0 })
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING))
    }
    func testThresholdCrossingIncludesExactFiveMillisecondPreroll() {
        let dsp = DSP()
        dsp.render([Float](repeating: 0.02, count: 500))
        dsp.arm()
        dsp.render([0.099])
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_ARMED))
        dsp.render([0.1])
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING))
        XCTAssertEqual(dsp.snapshot.recorded, 241) // 240 history + triggering sample
        dsp.silence(4558)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING))
        XCTAssertEqual(dsp.snapshot.recorded, 4799)
        dsp.silence(1)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING))
        XCTAssertEqual(dsp.snapshot.recorded, 4800)
        XCTAssertEqual(dsp.snapshot.position, 0)
    }
    func testRightChannelCanTriggerAndStereoIsPreserved() {
        let dsp = DSP()
        dsp.silence(5000)
        dsp.arm()
        dsp.render([Float](repeating: 0.04, count: 4560), [Float](repeating: 0.4, count: 4560))
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING))
        let out = dsp.silence(600)
        XCTAssertEqual(out.0[500], 0.04, accuracy: 0.0001)
        XCTAssertEqual(out.1[500], 0.4, accuracy: 0.0001)
    }
    func testTriggerAttackSurvivesPrerollAndBoundaryFade() {
        let dsp = DSP()
        dsp.silence(5000)
        dsp.arm()
        var input = [Float](repeating: 0.2, count: 4560)
        input[0] = 0.87
        dsp.render(input)
        let output = dsp.silence(500).0
        XCTAssertEqual(output[240], 0.87, accuracy: 0.0001)
        XCTAssertEqual(output[241], 0.2, accuracy: 0.0001)
    }
    func testExactPeriodAcrossManyWraps() {
        let dsp = DSP()
        dsp.makeLoop()
        dsp.silence(4800 * 37 + 123)
        XCTAssertEqual(dsp.snapshot.cycles, 37)
        XCTAssertEqual(dsp.snapshot.position, 123)
        XCTAssertEqual(dsp.snapshot.length, 4800)
    }
    func testRenderQuantumDoesNotChangeTriggerCaptureOrPlayback() {
        let total = 18000
        var input = [Float](repeating: 0.02, count: total)
        for i in 727..<6000 { input[i] = 0.3 + 0.1 * Float(sin(Double(i) / 37)) }
        let a = DSP(), b = DSP()
        a.arm(6001); b.arm(6001)
        let reference = a.render(input).0
        var chunked: [Float] = []
        var p = 0
        let quanta = [32, 1, 127, 256, 63, 511, 1024, 17]
        var n = 0
        while p < total {
            let end = min(total, p + quanta[n % quanta.count])
            chunked += b.render(Array(input[p..<end])).0
            p = end; n += 1
        }
        XCTAssertEqual(reference, chunked)
        XCTAssertEqual(a.snapshot.position, b.snapshot.position)
        XCTAssertEqual(a.snapshot.cycles, b.snapshot.cycles)
    }
    func testWrapHasZeroEndpointsAndKeepsFullLength() {
        let dsp = DSP()
        dsp.makeLoop()
        let out = dsp.silence(9600).0
        XCTAssertEqual(out[4799], 0, accuracy: 0.000001)
        XCTAssertEqual(out[4800], 0, accuracy: 0.000001)
        XCTAssertLessThan(abs(out[4798] - out[4799]), 0.001)
        XCTAssertEqual(dsp.snapshot.cycles, 2)
        XCTAssertEqual(dsp.snapshot.position, 0)
    }
    func testStopRetainsLoopAndPlayRestartsAtBeginning() {
        let dsp = DSP()
        dsp.makeLoop(); dsp.silence(700)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0))
        let tail = dsp.silence(512).0
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED))
        XCTAssertEqual(dsp.snapshot.length, 4800)
        XCTAssertTrue(tail.suffix(300).allSatisfy { $0 == 0 })
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0))
        dsp.silence(200)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING))
        XCTAssertEqual(dsp.snapshot.position, 200)
    }
    func testClearRemovesLoopWaveformAndFadesToSilence() {
        let dsp = DSP()
        dsp.makeLoop(); dsp.silence(700)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_CLEAR), 0))
        let out = dsp.render([Float](repeating: 0.8, count: 512)).0
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_EMPTY))
        XCTAssertEqual(dsp.snapshot.length, 0)
        XCTAssertTrue(out.suffix(300).allSatisfy { $0 == 0 })
        XCTAssertTrue((0..<256).allSatisfy { tl_waveform(dsp.core, UInt32($0)) == 0 })
    }
    func testStopDuringArmedOrRecordingCancelsIncompleteTake() {
        let dsp = DSP()
        dsp.arm(); dsp.silence(512)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0)); dsp.silence(1)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_EMPTY))
        dsp.arm(); dsp.render([0.5])
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0)); dsp.silence(1)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_EMPTY))
        XCTAssertEqual(dsp.snapshot.length, 0)
    }
    func testCommandQueueRejectsOverflowAndDrainsInOrder() {
        let dsp = DSP()
        for _ in 0..<32 { XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_CLEAR), 0)) }
        XCTAssertFalse(tl_command(dsp.core, Int32(TL_CMD_CLEAR), 0))
        dsp.silence(1)
        dsp.arm(); dsp.silence(1)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_ARMED))
    }
    func testNonFiniteInputCannotPoisonLoopOrMeter() {
        let dsp = DSP()
        dsp.arm()
        let out = dsp.render([.nan, .infinity, -.infinity, 0.2])
        XCTAssertTrue(out.0.allSatisfy(\.isFinite))
        XCTAssertTrue(dsp.snapshot.peak.isFinite)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING))
    }
    func testChangingThresholdWhileArmedWorksWithoutRearming() {
        let dsp = DSP()
        dsp.arm(); dsp.render([0.05])
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_ARMED))
        tl_set_threshold(dsp.core, 0.04)
        dsp.render([0.05])
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING))
    }
    func testSmallLoopDoesNotOverrunPrerollAndStaysFinite() {
        let dsp = DSP()
        dsp.arm(16)
        let out = dsp.render([Float](repeating: 0.5, count: 1000)).0
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING))
        XCTAssertEqual(dsp.snapshot.length, 16)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
    }
    func testThirtyTwoSampleQuantaKeepExactThresholdCaptureAndLoopLength() {
        let frames = tl_loop_frames(48000, 240, 2, 4)
        var input = [Float](repeating: 0.01, count: Int(frames) + 64)
        for i in 95..<input.count { input[i] = 0.4 }
        let whole = DSP(), small = DSP()
        whole.arm(frames); small.arm(frames)
        let reference = whole.render(input).0
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 32) {
            output += small.render(Array(input[start..<min(input.count, start + 32)])).0
        }
        XCTAssertEqual(reference, output)
        XCTAssertEqual(small.snapshot.length, frames)
        XCTAssertEqual(small.snapshot.recorded, frames)
        XCTAssertEqual(small.snapshot.state, Int32(TL_PLAYING))
        XCTAssertEqual(small.snapshot.position, 209)
    }

}
