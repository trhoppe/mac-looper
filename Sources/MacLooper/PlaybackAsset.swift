import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit

final class PlaybackAsset: @unchecked Sendable {
    let file: AVAudioFile
    let duration: Double
    // A fixed stereo/48k file branch avoids reconnecting a live guitar graph when
    // switching between MP3/WAV rates or mono/stereo sources. Conversion streams
    // bounded buffers to a local, OS-purgeable cache on the file-loading actor.
    init(_ url: URL) throws {
        let original = try AVAudioFile(forReading: url)
        let format = original.processingFormat
        if format.sampleRate == 48000 && format.channelCount == 2 && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved {
            file = original
        } else {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let key = "\(url.path)|\(info.fileSize ?? 0)|\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)|48000-stereo-v2"
            let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacLooper/Audio", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let converted = cache.appendingPathComponent(hash + ".caf")
            if !FileManager.default.fileExists(atPath: converted.path) {
                let temporary = cache.appendingPathComponent(UUID().uuidString + ".caf")
                do {
                    try Self.convert(original, to: temporary)
                    if FileManager.default.fileExists(atPath: converted.path) { try FileManager.default.removeItem(at: temporary) }
                    else { try FileManager.default.moveItem(at: temporary, to: converted) }
                } catch { try? FileManager.default.removeItem(at: temporary); throw error }
            }
            file = try AVAudioFile(forReading: converted)
        }
        duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, file.length <= Int64(UInt32.max) else { throw AudioFailure(message: "This audio file has no supported playable duration.") }
    }
    private static func convert(_ source: AVAudioFile, to url: URL) throws {
        let target = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
            throw AudioFailure(message: "This audio format could not be decoded for playback.")
        }
        // MP3 length is only an estimate. ExtAudioFile reports the actual EOF with
        // zero frames, avoiding AVAudioFile's nil NSError on a final compressed read.
        var decoder: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(source.url as CFURL, &decoder)
        guard status == noErr, let decoder else { throw AudioFailure(message: "Could not open backing audio (Core Audio \(status)).") }
        defer { ExtAudioFileDispose(decoder) }
        status = ExtAudioFileSetProperty(decoder, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), target.streamDescription)
        guard status == noErr else { throw AudioFailure(message: "Could not convert backing audio (Core Audio \(status)).") }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false]
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while true {
            try Task.checkCancellation()
            var frames: UInt32 = buffer.frameCapacity
            buffer.frameLength = buffer.frameCapacity
            status = ExtAudioFileRead(decoder, &frames, buffer.mutableAudioBufferList)
            guard status == noErr else { throw AudioFailure(message: "Could not decode backing audio (Core Audio \(status)).") }
            if frames == 0 { break }
            buffer.frameLength = frames
            try writer?.write(from: buffer)
        }
        writer = nil
    }
}
