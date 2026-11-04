import XCTest
import LooperCore

final class ManualRecordingTests: XCTestCase {
    func testManualCaptureIgnoresThresholdAndOldHistoryAndKeepsExactMaximum() {
        let dsp = DSP()
        dsp.render([Float](repeating: 0.8, count: 1000))
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 1501))
        XCTAssertTrue(dsp.render([Float](repeating: 0.04, count: 1500)).0.allSatisfy { $0 == 0 })
        XCTAssertEqual(dsp.snapshot.recorded, 1500)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING))
        dsp.render([0.04])
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING))
        XCTAssertEqual(dsp.snapshot.recorded, 1501)
        XCTAssertEqual(dsp.snapshot.position, 0)
        XCTAssertEqual((0..<256).map { tl_waveform(dsp.core, UInt32($0)) }.max(), 0.04)
        XCTAssertEqual(dsp.silence(500).0[300], 0.04, accuracy: 0.0001)
    }
    func testSecondPressLoopsExactPartialTakeAcrossDifferentRenderQuanta() {
        for quantum in [1, 32, 127, 512] {
            let dsp = DSP()
            XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 4800))
            var remaining = 1501
            while remaining > 0 {
                let n = min(quantum, remaining)
                dsp.render([Float](repeating: 0.4, count: n), [Float](repeating: 0.2, count: n))
                remaining -= n
            }
            XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 4800))
            let out = dsp.silence(1501 * 37 + 123)
            XCTAssertEqual(dsp.snapshot.length, 1501)
            XCTAssertEqual(dsp.snapshot.recorded, 1501)
            XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING))
            XCTAssertEqual(dsp.snapshot.cycles, 37)
            XCTAssertEqual(dsp.snapshot.position, 123)
            // Allow the existing playback-volume smoothing to reach unity.
            XCTAssertEqual(out.0[3302], 0.4, accuracy: 0.0001)
            XCTAssertEqual(out.1[3302], 0.2, accuracy: 0.0001)
            XCTAssertEqual(out.0[1500], 0)
            XCTAssertEqual(out.0[1501], 0)
            XCTAssertEqual(tl_waveform(dsp.core, 255), 0.4)
        }
    }
    func testRecordWhileArmedStartsNowWithoutPreroll() {
        let dsp = DSP(); dsp.render([Float](repeating: 0.9, count: 500))
        dsp.arm(); dsp.silence(32)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 4800))
        dsp.render([0.04])
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING))
        XCTAssertEqual(dsp.snapshot.recorded, 1)
        XCTAssertEqual(tl_waveform(dsp.core, 0), 0.04)
    }
    func testRecordCanFinishThresholdTriggeredTakeAndResumeAfterStop() {
        let dsp = DSP(); dsp.arm(); dsp.render([Float](repeating: 0.5, count: 1000))
        XCTAssertEqual(dsp.snapshot.recorded, 1240)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 4800))
        dsp.silence(32)
        XCTAssertEqual(dsp.snapshot.length, 1240)
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0)); dsp.silence(32)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED))
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_PLAY_STOP), 0)); dsp.silence(32)
        XCTAssertEqual(dsp.snapshot.position, 32)
        XCTAssertEqual(dsp.snapshot.length, 1240)
    }
    func testNoEmptyLoopFromRapidPressesAndCompletedTakeCannotBeOverwritten() {
        let dsp = DSP()
        for _ in 0..<2 { XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 32)) }
        dsp.silence(1)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_RECORDING))
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 32)); dsp.silence(1)
        XCTAssertEqual(dsp.snapshot.length, 1)
        XCTAssertTrue(dsp.silence(500).0.allSatisfy(\.isFinite))
        for command in [TL_CMD_RECORD, TL_CMD_ARM] { XCTAssertTrue(tl_command(dsp.core, Int32(command), 4800)) }
        dsp.silence(32)
        XCTAssertEqual(dsp.snapshot.length, 1)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_PLAYING))
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_CLEAR), 0)); dsp.silence(32)
        XCTAssertEqual(dsp.snapshot.length, 0)
        XCTAssertTrue((0..<256).allSatisfy { tl_waveform(dsp.core, UInt32($0)) == 0 })
    }
    func testRecordAtAutomaticEndDoesNotEraseOrRestartLoop() {
        let dsp = DSP()
        XCTAssertFalse(tl_command(dsp.core, Int32(TL_CMD_RECORD), 0))
        XCTAssertFalse(tl_command(dsp.core, Int32(TL_CMD_RECORD), 100001))
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 32))
        dsp.render([Float](repeating: 0.5, count: 32))
        XCTAssertTrue(tl_command(dsp.core, Int32(TL_CMD_RECORD), 32)); dsp.silence(1)
        XCTAssertEqual(dsp.snapshot.length, 32)
        XCTAssertEqual(dsp.snapshot.position, 1)
        tl_suspend(dsp.core)
        XCTAssertEqual(dsp.snapshot.state, Int32(TL_STOPPED))
        XCTAssertEqual(dsp.snapshot.length, 32)
    }
}
