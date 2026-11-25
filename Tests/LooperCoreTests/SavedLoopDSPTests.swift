import XCTest
import LooperCore

final class SavedLoopDSPTests: XCTestCase {
    private func load(_ dsp: DSP, frames: Int = 4800) {
        let l = [Float](repeating: 0.5, count: frames), r = l.map { -$0 }
        XCTAssertTrue(tl_begin_edit(dsp.core))
        XCTAssertTrue(l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in tl_load_loop(dsp.core, lp.baseAddress, rp.baseAddress, UInt32(frames)) } })
        tl_end_edit(dsp.core)
    }
    private func render(_ dsp: DSP, _ frames: Int, offset: Int64) -> [Float] {
        var l = [Float](repeating: 0, count: frames), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            tl_process_timed(dsp.core, nil, nil, lp.baseAddress, rp.baseAddress, UInt32(frames), offset)
        } }
        return l
    }
    func testRecallStaysStoppedAndWaitingStartsAtExactSampleAcrossQuanta() {
        for quantum in [32, 127, 512] {
            let dsp = DSP(); load(dsp)
            XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED))
            XCTAssertTrue(dsp.silence(quantum).0.allSatisfy { $0 == 0 })
            XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_SYNC), 0))
            XCTAssertTrue(render(dsp, quantum, offset: Int64(quantum + 17)).allSatisfy { $0 == 0 })
            XCTAssertEqual(dsp.snapshot.state, Int32(TL_WAITING)); XCTAssertEqual(dsp.snapshot.position, 0)
            let output = render(dsp, quantum, offset: 17)
            XCTAssertTrue(output.prefix(18).allSatisfy { $0 == 0 }) // frame 0 has a seam fade
            XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING)); XCTAssertEqual(dsp.snapshot.position, UInt32(quantum - 17))
        }
    }
    func testWaitingCanCancelClearSuspendOrStartWhenDrummerStops() {
        let dsp = DSP(); load(dsp)
        for command in [TL_CMD_PLAY_SYNC, TL_CMD_CLEAR] {
            load(dsp)
            XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_SYNC), 0)); _ = render(dsp, 32, offset: 1000)
            XCTAssertTrue(tl_command(dsp.core, Int32(command), 0)); _ = render(dsp, 32, offset: 1000)
            XCTAssertEqual(dsp.snapshot.state, Int32(command == TL_CMD_CLEAR ? TL_EMPTY : TL_STOPPED))
        }
        load(dsp); XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_SYNC), 0)); _ = render(dsp, 32, offset: 1000)
        tl_suspend(dsp.core); XCTAssertEqual(dsp.snapshot.length, 4800); XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED))
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_SYNC), 0)); _ = render(dsp, 32, offset: -1)
        XCTAssertEqual(dsp.snapshot.position, 32); XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING))
    }
    func testEditingGateAndCopyKeepRawStereoAndDoNotAutoplay() {
        let dsp = DSP(); load(dsp, frames: 1501)
        XCTAssertTrue(tl_begin_edit(dsp.core)); defer { tl_end_edit(dsp.core) }
        XCTAssertTrue(dsp.silence(32).0.allSatisfy { $0 == 0 })
        XCTAssertFalse(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0))
        var l = [Float](repeating: 0, count: 1501), r = l
        XCTAssertTrue(l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in tl_copy_loop(dsp.core, lp.baseAddress, rp.baseAddress, 1501) } })
        XCTAssertEqual(l, Array(repeating: 0.5, count: 1501)); XCTAssertEqual(r, Array(repeating: -0.5, count: 1501))
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED))
    }
    func testMaximumLengthSnapshotKeepsRenderingAndHonorsStop() throws {
        let frames = 3_072_000
        let dsp = DSP(capacity: UInt32(frames))
        load(dsp, frames: frames)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0))
        dsp.silence(256)
        XCTAssertEqual(tl_pin_snapshot(dsp.core), UInt32(frames))
        XCTAssertFalse(tl_command(dsp.core, Int32(TL_CMD_CLEAR), 0))
        var left = [Float](repeating: 0, count: frames), right = left
        for _ in 0..<100 {
            XCTAssertTrue(dsp.silence(32).0.allSatisfy { $0 > 0 })
        }
        XCTAssertEqual(dsp.snapshot.position, 3456)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0))
        dsp.silence(32)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED))
        XCTAssertTrue(tl_copy_snapshot(dsp.core, &left, &right, UInt32(frames)))
        tl_unpin_snapshot(dsp.core)
        XCTAssertEqual(left.last, 0.5)
        XCTAssertEqual(right.last, -0.5)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_CLEAR), 0))
        XCTAssertEqual(tl_pin_snapshot(dsp.core), 0, "A queued Clear invalidates the snapshot")
    }

    func testRecordingDoesNotWaitForDrummerAndInvalidLoadPreservesTake() {
        let dsp = DSP()
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 1501)); _ = render(dsp, 32, offset: 90000)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING)); XCTAssertEqual(dsp.snapshot.recorded, 32)
        load(dsp); XCTAssertTrue(tl_begin_edit(dsp.core))
        let invalid = [Float](repeating: .nan, count: 32)
        XCTAssertFalse(invalid.withUnsafeBufferPointer { tl_load_loop(dsp.core, $0.baseAddress, $0.baseAddress, 32) })
        tl_end_edit(dsp.core); XCTAssertEqual(dsp.snapshot.length, 4800)
    }
    func testSuspensionDuringFileTransferRetainsTakeAndNeverAutoplays() {
        let dsp = DSP(); load(dsp)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0)); dsp.silence(32)
        XCTAssertTrue(tl_begin_edit(dsp.core))
        tl_suspend(dsp.core) // File worker owns samples until end_edit.
        tl_end_edit(dsp.core)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED)); XCTAssertEqual(dsp.snapshot.length, 4800)
        XCTAssertTrue(dsp.silence(512).0.allSatisfy { $0 == 0 })
    }
    func testRepeatedTransfersWhileCallbacksContinue() {
        let dsp = DSP(); load(dsp)
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            for _ in 0..<2000 { dsp.silence(32); Thread.sleep(forTimeInterval: 0.00001) }
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        var left = [Float](repeating: 0, count: 4800), right = left
        for _ in 0..<100 {
            var ready = false
            for _ in 0..<1000 {
                if tl_begin_edit(dsp.core) { ready = true; break }
                Thread.sleep(forTimeInterval: 0.00001)
            }
            XCTAssertTrue(ready)
            if ready {
                XCTAssertTrue(left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in tl_copy_loop(dsp.core, l.baseAddress, r.baseAddress, 4800) } })
                XCTAssertTrue(left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in tl_load_loop(dsp.core, l.baseAddress, r.baseAddress, 4800) } })
            }
            tl_end_edit(dsp.core)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED)); XCTAssertEqual(left.first, 0.5); XCTAssertEqual(right.first, -0.5)
    }
}
