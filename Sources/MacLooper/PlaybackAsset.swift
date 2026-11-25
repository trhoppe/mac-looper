import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit

final class PlaybackAsset: @unchecked Sendable {
    let file: AVAudioFile
    let duration: Double
    private let cachedURL: URL?
    private static let cacheLock = NSLock()
    private static var openCacheFiles: [URL: Int] = [:]
    private static let cacheBudget = 1_024 * 1_024 * 1_024

    deinit {
        if let cachedURL {
            DispatchQueue.global(qos: .utility).async {
                Self.cacheLock.withLock {
                    if let count = Self.openCacheFiles[cachedURL], count > 1 { Self.openCacheFiles[cachedURL] = count - 1 }
                    else { Self.openCacheFiles.removeValue(forKey: cachedURL) }
                    Self.pruneCache(cachedURL.deletingLastPathComponent())
                }
            }
        }
    }
    // A fixed stereo/48k file branch avoids reconnecting a live guitar graph when
    // switching between MP3/WAV rates or mono/stereo sources. Conversion streams
    // bounded buffers to a local, OS-purgeable cache on the file-loading actor.
    init(_ url: URL) throws {
        let original = try AVAudioFile(forReading: url)
        let format = original.processingFormat
        if format.sampleRate == 48000 && format.channelCount == 2 && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved {
            file = original
            cachedURL = nil
        } else {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let key = "\(url.path)|\(info.fileSize ?? 0)|\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)|48000-stereo-v2"
            let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacLooper/Audio", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let converted = cache.appendingPathComponent(hash + ".caf")
            if let hit = try Self.cacheLock.withLock({ try Self.openCached(converted) }) {
                file = hit
                Self.cacheLock.withLock { Self.pruneCache(cache) }
            } else {
                let temporary = cache.appendingPathComponent(UUID().uuidString + ".caf")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Self.convert(original, to: temporary)
                file = try Self.cacheLock.withLock {
                    if !FileManager.default.fileExists(atPath: converted.path) {
                        try FileManager.default.moveItem(at: temporary, to: converted)
                    }
                    guard let asset = try Self.openCached(converted) else {
                        throw AudioFailure(message: "The converted audio could not be opened.")
                    }
                    Self.pruneCache(cache)
                    return asset
                }
            }
            cachedURL = converted
        }
        duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, file.length <= Int64(UInt32.max) else { throw AudioFailure(message: "This audio file has no supported playable duration.") }
    }
    // Only published, hash-named conversions are eligible. A conversion in
    // progress and files leased by the player stay available.
    private static func openCached(_ url: URL) throws -> AVAudioFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= Int64(UInt32.max) else {
            throw AudioFailure(message: "This audio file has no supported playable duration.")
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        openCacheFiles[url, default: 0] += 1
        return file
    }
    private static func pruneCache(_ folder: URL) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        let files = urls.compactMap { url -> (url: URL, bytes: Int, used: Date)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "caf", name.utf8.count == 64, name.allSatisfy(\.isHexDigit),
                  let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true,
                  let bytes = info.fileSize else { return nil }
            return (url, bytes, info.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.bytes }
        guard total > cacheBudget else { return }
        for file in files.sorted(by: { $0.used < $1.used }) where openCacheFiles[file.url] == nil {
            do {
                try FileManager.default.removeItem(at: file.url)
                total -= file.bytes
            } catch { continue }
            if total <= cacheBudget { break }
        }
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
