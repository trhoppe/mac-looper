import XCTest
import AVFoundation
@testable import MacLooper

final class PlaybackAssetTests: XCTestCase {
    func testMonoFortyFourKBackingConvertsWithoutChangingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Mono.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        input.frameLength = 44100
        input.floatChannelData![0].initialize(repeating: 0.1, count: 44100)
        try writer!.write(from: input); writer = nil
        let bytes = try Data(contentsOf: url)
        let a = try PlaybackAsset(url), cached = try PlaybackAsset(url)
        XCTAssertEqual(a.file.processingFormat.sampleRate, 48000)
        XCTAssertEqual(a.file.processingFormat.channelCount, 2)
        XCTAssertEqual(a.duration, 1, accuracy: 0.002)
        XCTAssertEqual(a.file.url, cached.file.url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let out = AVAudioPCMBuffer(pcmFormat: a.file.processingFormat, frameCapacity: 2048)!
        try a.file.read(into: out)
        XCTAssertEqual(out.floatChannelData![0][1000], 0.1, accuracy: 0.002)
        XCTAssertEqual(out.floatChannelData![1][1000], 0.1, accuracy: 0.002)
    }
}
