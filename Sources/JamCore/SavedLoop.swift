import Foundation

/// A portable, lossless stereo take. Audio is dry float32 PCM; playback gain is
/// deliberately not baked in. Duration is the actual take, including early finishes.
public struct SavedLoop: Codable, Sendable {
    public static let maximumFileBytes = 105_000_000
    public let version: Int
    public let sampleRate: Double
    public let bpm: Double
    public let bars: Int
    public let leftPCM: Data
    public let rightPCM: Data
    public var frames: Int { leftPCM.count / MemoryLayout<Float>.size }
    public var duration: Double { Double(frames) / sampleRate }

    public init(sampleRate: Double, bpm: Double, bars: Int, left: [Float], right: [Float]) throws {
        version = 1; self.sampleRate = sampleRate; self.bpm = bpm; self.bars = bars
        leftPCM = left.withUnsafeBytes { Data($0) }; rightPCM = right.withUnsafeBytes { Data($0) }
        try validate()
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> SavedLoop {
        guard data.count <= maximumFileBytes else { throw LoopFileError.invalid }
        do {
            let loop = try PropertyListDecoder().decode(Self.self, from: data)
            try loop.validate(); return loop
        } catch { throw LoopFileError.invalid }
    }
    public func channels() -> (left: [Float], right: [Float]) {
        // Mac and iPad both use little-endian IEEE float32. Copy into aligned
        // storage rather than binding potentially unaligned file data to Float.
        func samples(_ data: Data) -> [Float] {
            var result = [Float](repeating: 0, count: data.count / 4)
            _ = result.withUnsafeMutableBytes { target in data.copyBytes(to: target) }
            return result
        }
        return (samples(leftPCM), samples(rightPCM))
    }
    private func validate() throws {
        guard version == 1, sampleRate.isFinite, (8000...192000).contains(sampleRate),
              bpm.isFinite, (30...240).contains(bpm), (1...8).contains(bars),
              leftPCM.count == rightPCM.count, leftPCM.count % 4 == 0,
              frames >= 16, Double(frames) <= sampleRate * 64 + 4 else { throw LoopFileError.invalid }
        for data in [leftPCM, rightPCM] {
            let valid = data.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))).isFinite
                }
            }
            guard valid else { throw LoopFileError.invalid }
        }
    }
}

public enum LoopFileError: LocalizedError {
    case invalid, unavailable, transfer
    public var errorDescription: String? {
        switch self {
        case .invalid: "This isn’t a supported Mac Jams loop file, or its audio is damaged."
        case .unavailable: "Finish recording a loop before saving it."
        case .transfer: "The loop couldn’t be transferred. Your current loop has been kept. Try again."
        }
    }
}
