import AVFoundation
import LooperCore
import LooperAudioUnit
import JamCore

/// The host configuration gate prevents reallocations; retaining the AU also
/// keeps its core alive if shutdown occurs while this worker finishes a copy.
final class LoopAudioTransfer: @unchecked Sendable {
    private let unit: MLGuitarLoopAudioUnit
    init(unit: MLGuitarLoopAudioUnit) { self.unit = unit }
    private func edit<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let core = unit.core else { throw LoopFileError.transfer }
        defer { tl_end_edit(core) }
        for _ in 0..<1000 {
            if tl_begin_edit(core) { return try body(core) }
            Thread.sleep(forTimeInterval: 0.001) // Worker only; rendering never waits.
        }
        throw LoopFileError.transfer
    }
    func copy(bpm: Double, bars: Int) throws -> SavedLoop {
        let (rate, left, right) = try edit { core in
            let frames = tl_snapshot(core).length
            guard frames >= 16 else { throw LoopFileError.unavailable }
            var left = [Float](repeating: 0, count: Int(frames)), right = left
            let copied = left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in tl_copy_loop(core, l.baseAddress, r.baseAddress, frames) }
            }
            guard copied else { throw LoopFileError.unavailable }
            return (tl_sample_rate(core), left, right)
        }
        return try SavedLoop(sampleRate: rate, bpm: bpm, bars: bars, left: left, right: right)
    }
    func load(_ loop: SavedLoop) throws {
        guard let core = unit.core else { throw LoopFileError.transfer }
        // Conversion and validation happen before closing the render gate.
        let channels = try Self.resampled(loop, rate: tl_sample_rate(core))
        try edit { core in
            let loaded = channels.left.withUnsafeBufferPointer { l in
                channels.right.withUnsafeBufferPointer { r in tl_load_loop(core, l.baseAddress, r.baseAddress, UInt32(l.count)) }
            }
            guard loaded else { throw LoopFileError.transfer }
        }
    }
    static func resampled(_ loop: SavedLoop, rate: Double) throws -> (left: [Float], right: [Float]) {
        let channels = loop.channels()
        if rate == loop.sampleRate { return channels }
        guard let source = AVAudioFormat(standardFormatWithSampleRate: loop.sampleRate, channels: 2),
              let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(loop.frames)) else { throw LoopFileError.transfer }
        input.frameLength = AVAudioFrameCount(loop.frames)
        channels.left.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: loop.frames) }
        channels.right.withUnsafeBufferPointer { input.floatChannelData![1].update(from: $0.baseAddress!, count: loop.frames) }
        let frames = Int((Double(loop.frames) * rate / loop.sampleRate).rounded())
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames + 1024)) else { throw LoopFileError.transfer }
        converter.primeMethod = .none
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard status != .error, error == nil, Int(output.frameLength) >= frames else { throw error ?? LoopFileError.transfer }
        return (Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: frames)),
                Array(UnsafeBufferPointer(start: output.floatChannelData![1], count: frames)))
    }
}
