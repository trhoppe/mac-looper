import XCTest
import AVFoundation
import AudioToolbox
import LooperAudioUnit

final class DrumGainTests: XCTestCase {
    func testMutedGainStillPullsInstrumentAndRampsWithoutClicks() throws {
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x64676169,
            componentManufacturer: 0x4D614C70, componentFlags: 0, componentFlagsMask: 0)
        let unit = try MLDrumGainAudioUnit(componentDescription: d, options: [])
        try unit.allocateRenderResources(); defer { unit.deallocateRenderResources() }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        var pulls = 0
        func render() -> [Float] {
            buffer.frameLength = 32
            var flags: AudioUnitRenderActionFlags = [], time = AudioTimeStamp()
            time.mFlags = .sampleTimeValid
            let status = unit.internalRenderBlock(&flags, &time, 32, 0, buffer.mutableAudioBufferList, nil) { _, _, frames, _, input in
                pulls += 1
                for b in UnsafeMutableAudioBufferListPointer(input) {
                    b.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.5, count: Int(frames))
                }
                return noErr
            }
            XCTAssertEqual(status, noErr)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 32))
        }
        XCTAssertTrue(render().allSatisfy { $0 == 0 }); XCTAssertEqual(pulls, 1)
        unit.volume = 1
        let attack = render()
        XCTAssertGreaterThan(attack.last!, attack.first!)
        XCTAssertLessThan(attack.last!, 0.5)
        for _ in 0..<6 { _ = render() }
        XCTAssertEqual(render().last!, 0.5, accuracy: 0.00001)
        unit.volume = 0
        let release = render()
        XCTAssertLessThan(release.last!, release.first!)
        for _ in 0..<6 { _ = render() }
        XCTAssertTrue(render().allSatisfy { $0 == 0 })
        XCTAssertEqual(pulls, 17)
        unit.volume = .nan; XCTAssertEqual(unit.volume, 0)
        unit.volume = 2; XCTAssertEqual(unit.volume, 1)
    }
}
