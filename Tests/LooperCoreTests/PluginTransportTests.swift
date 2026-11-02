import XCTest
import AudioToolbox
import LooperAudioUnit

final class PluginTransportTests: XCTestCase {
    private func makeUnit() throws -> MLGuitarLoopAudioUnit {
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6D6C6C70,
            componentManufacturer: 0x4D614C70, componentFlags: 0, componentFlagsMask: 0)
        return try MLGuitarLoopAudioUnit(componentDescription: d, options: [])
    }
    func testBeatTempoMeterAndStopRestartAreSampleBased() throws {
        let unit = try makeUnit(), clock = MLPluginTransport()
        clock.attach(to: unit); defer { clock.detach() }
        clock.configureSampleRate(48000); clock.tempo = 120; clock.isPlaying = true
        for _ in 0..<1500 { clock.beginRenderFrames(32); clock.endRenderFrames(32) }
        XCTAssertEqual(clock.beatPosition, 2, accuracy: 1e-10)
        clock.tempo = 90
        for _ in 0..<750 { clock.beginRenderFrames(128); clock.endRenderFrames(128) }
        XCTAssertEqual(clock.beatPosition, 5, accuracy: 1e-10)
        var bpm = 0.0, numerator = 0.0, denominator = 0, beat = 0.0, next = 0, downbeat = 0.0
        let music = try XCTUnwrap(unit.musicalContextBlock)
        XCTAssertTrue(music(&bpm, &numerator, &denominator, &beat, &next, &downbeat))
        XCTAssertEqual(bpm, 90); XCTAssertEqual(numerator, 4); XCTAssertEqual(denominator, 4)
        XCTAssertEqual(beat, 5, accuracy: 1e-10); XCTAssertEqual(downbeat, 4)
        clock.isPlaying = false; clock.beginRenderFrames(32); clock.endRenderFrames(32)
        XCTAssertEqual(clock.beatPosition, 5, accuracy: 1e-10)
        var flags: AUHostTransportStateFlags = [], sample = 0.0, start = 0.0, end = 0.0
        let state = try XCTUnwrap(unit.transportStateBlock)
        XCTAssertTrue(state(&flags, &sample, &start, &end))
        XCTAssertFalse(flags.contains(.moving)); XCTAssertTrue(flags.contains(.changed))
        XCTAssertEqual(sample, 144000)
        clock.isPlaying = true; clock.beginRenderFrames(32)
        XCTAssertTrue(state(&flags, &sample, nil, nil)); XCTAssertEqual(sample, 0)
        XCTAssertTrue(flags.contains(.moving)); XCTAssertTrue(flags.contains(.changed))
        clock.endRenderFrames(32)
        XCTAssertEqual(clock.renderedFrames, 32)
    }
    func testInvalidControlsAndMutedStopStartDoNotLoseRestart() throws {
        let unit = try makeUnit(), clock = MLPluginTransport()
        clock.attach(to: unit); defer { clock.detach() }
        clock.tempo = 120; clock.tempo = .nan; clock.tempo = 0; clock.tempo = .infinity
        XCTAssertEqual(clock.tempo, 120)
        clock.isPlaying = true; clock.beginRenderFrames(32); clock.endRenderFrames(32)
        // A muted source may not be pulled while stopped. The next Play still resets.
        clock.isPlaying = false; clock.isPlaying = true; clock.beginRenderFrames(32)
        var sample = -1.0
        XCTAssertTrue(unit.transportStateBlock!(nil, &sample, nil, nil)); XCTAssertEqual(sample, 0)
        XCTAssertTrue(unit.musicalContextBlock!(nil, nil, nil, nil, nil, nil))
    }
    func testTransportChangeSurvivesSkippedQueriesAndIsConsumedOnce() throws {
        let unit = try makeUnit(), clock = MLPluginTransport()
        clock.attach(to: unit); defer { clock.detach() }
        clock.isPlaying = true
        for _ in 0..<10 { clock.beginRenderFrames(32); clock.endRenderFrames(32) }
        var flags: AUHostTransportStateFlags = []
        XCTAssertTrue(unit.transportStateBlock!(&flags, nil, nil, nil))
        XCTAssertTrue(flags.contains(.changed)); XCTAssertTrue(flags.contains(.moving))
        XCTAssertTrue(unit.transportStateBlock!(&flags, nil, nil, nil))
        XCTAssertFalse(flags.contains(.changed)); XCTAssertTrue(flags.contains(.moving))
    }

}
