import Foundation

/// A private offline copy of the user's AM4-Edit Amp library.
public struct AM4AmpLibrary: Decodable, Sendable {
    public let version: Int
    public let entries: [AM4AmpLibraryEntry]

    public static let shared: Self = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "AmpLibrary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              result.version == 1,
              Set(result.entries.map(\.id)).count == result.entries.count,
              result.entries.allSatisfy({ $0.blockFile != nil }) else {
            preconditionFailure("Missing or invalid Amp library")
        }
        return result
    }()

    public func entry(_ id: String) -> AM4AmpLibraryEntry? { entries.first { $0.id == id } }
}

public struct AM4AmpLibraryEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let file: Data
    public var blockFile: AM4AmpBlockFile? {
        guard let parsed = AM4AmpBlockFile(data: file), parsed.name == name,
              parsed.id == id else { return nil }
        return parsed
    }
}

/// Native version-5 AM4 single-channel library files contain Amp and Cab dumps.
/// Keep their original data: parameter-by-parameter reconstruction would omit
/// settings that are not on the currently visible edit page.
public struct AM4AmpBlockFile: Sendable {
    public let id: String
    public let name: String
    public let sourceChannel: Int
    public let dumps: [[AM4Message]]

    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard (64...32_768).contains(bytes.count) else { return nil }
        func integer(_ offset: Int, _ count: Int) -> Int? {
            guard offset >= 0, offset + count <= bytes.count else { return nil }
            return (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard integer(0, 2) == 5, integer(2, 2) == 0x15,
              integer(22, 4) == 10, integer(26, 4) == 1,
              let channel = integer(30, 4), (0..<4).contains(channel),
              let nameLength = integer(34, 4), (1...128).contains(nameLength),
              38 + nameLength + 12 <= bytes.count,
              let name = String(bytes: bytes[38..<(38 + nameLength)], encoding: .utf8),
              !name.contains("\0") else { return nil }
        let uuid = bytes[6..<22].map { String(format: "%02x", $0) }.joined()
        var offset = 38 + nameLength
        guard integer(offset, 4) == 0, integer(offset + 4, 4) == 2 else { return nil }
        offset += 8
        var dumps: [[AM4Message]] = []
        for expectedBlock in [0x3A, 0x3E] {
            guard let count = integer(offset, 4), (20...16_384).contains(count),
                  offset + 4 + count <= bytes.count else { return nil }
            offset += 4
            let end = offset + count
            var messages: [AM4Message] = []
            while offset < end {
                guard let stop = bytes[offset..<end].firstIndex(of: 0xF7),
                      let message = AM4Message(bytes: Array(bytes[offset...stop])) else { return nil }
                messages.append(message)
                offset = stop + 1
            }
            guard let header = messages.first, header.function == 0x74,
                  header.payload.count == 4, header.payload[0] == expectedBlock, header.payload[1] == 0,
                  messages.last?.function == 0x76, messages.last?.payload.isEmpty == true,
                  messages.count >= 3 else { return nil }
            let announced = Int(header.payload[2]) + Int(header.payload[3]) * 128
            var words = 0
            for message in messages.dropFirst().dropLast() {
                guard message.function == 0x75, message.payload.count >= 2 else { return nil }
                let count = Int(message.payload[0]) + Int(message.payload[1]) * 128
                guard (1...256).contains(count), message.payload.count == count * 3 + 2 else { return nil }
                words += count
            }
            guard words == announced else { return nil }
            dumps.append(messages)
        }
        self.id = uuid
        self.name = name
        self.sourceChannel = channel
        self.dumps = dumps
    }
}

public struct AM4AmpSelection: Codable, Sendable {
    public let context: AM4AmpContext
    public let expectedModel: Int
    public let model: Int?
    public let libraryID: String?
    public let channel: Int?

    public init(context: AM4AmpContext, expectedModel: Int, model: Int? = nil, libraryID: String? = nil, channel: Int? = nil) {
        self.context = context
        self.expectedModel = expectedModel
        self.model = model
        self.libraryID = libraryID
        self.channel = channel
    }

    public var isValid: Bool {
        guard context.isValid, context.channel != nil,
              AM4AmpCatalog.shared.models.indices.contains(expectedModel),
              [model != nil, libraryID != nil, channel != nil].filter({ $0 }).count == 1 else { return false }
        if let model { return AM4AmpCatalog.shared.models.indices.contains(model) }
        if let channel { return (0..<4).contains(channel) }
        return libraryID.flatMap(AM4AmpLibrary.shared.entry) != nil
    }

}

extension AM4Message {
    public static var ampChannelRequest: [UInt8] {
        request(function: 1, payload: [58, 0, 82, 15, 13, 0, 0, 0, 0, 0])
    }
    public var isAmpChannelReply: Bool {
        function == 1 && payload.count == 56 && Array(payload.prefix(10)) == [58, 0, 82, 15, 13, 0, 0, 0, 40, 0]
    }
    public var ampChannel: Int? {
        guard isAmpChannelReply, let bytes = Self.unpack(Array(payload.dropFirst(10)), count: 40) else { return nil }
        // Virtual BLOCK_CHANNEL differs from ordinary parameter records. Its
        // first word is undefined; the channel is UInt32 at 4, plus A/B/C/D at 8.
        let channel = (0..<4).reduce(0) { $0 | (Int(bytes[4 + $1]) << ($1 * 8)) }
        guard (0..<4).contains(channel), bytes[8] == 65 + channel, bytes[9] == 0 else { return nil }
        return channel
    }
    public static func ampChannelWrite(_ channel: Int) -> [UInt8]? {
        guard (0..<4).contains(channel) else { return nil }
        let bits = Float(channel).bitPattern
        return request(function: 1, payload: [58, 0, 82, 15, 1, 0, 0, 0, 4, 0] + pack((0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }))
    }
    public static func libraryTransferMode(block: Int) -> [UInt8]? {
        guard [50, 58, 62, 66, 70, 118, 119, 122].contains(block) else { return nil }
        // AM4-Edit sends this exact marker before uploading either merged bank.
        return request(function: 1, payload: [UInt8(block), 0, 23, 1, 1, 0, 0, 0, 4, 0] + pack([0, 0, 128, 63]))
    }
    public static func ampModelWrite(_ command: AM4AmpSelection) -> [UInt8]? {
        guard command.isValid, let model = command.model,
              let definition = AM4AmpCatalog.shared.definition("58:10") else { return nil }
        let bits = Float(model).bitPattern
        let raw = (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
        return parameterFrame(definition, action: 1, raw: raw)
    }
}

public struct AM4EffectBank: Equatable, Sendable {
    public let block: Int
    public let words: [UInt32]
    public var stride: Int { words.count / 4 }
    public var isValid: Bool {
        [50, 58, 62, 66, 70, 118, 119, 122].contains(block) && (40...4096).contains(words.count) && words.count % 4 == 0 && words.allSatisfy { $0 < 1 << 21 }
    }
    public init(block: Int, words: [UInt32]) { self.block = block; self.words = words }

    public func merging(_ source: Self, from sourceChannel: Int, into targetChannel: Int) -> Self? {
        guard isValid, source.isValid, block == source.block,
              (0..<4).contains(sourceChannel), (0..<4).contains(targetChannel),
              source.stride <= stride, stride - source.stride <= 1 else { return nil }
        var merged = words
        // Older native AM4 files omit one trailing parameter. Keep that newer
        // parameter's current value; the established parameter IDs are stable.
        for index in 0..<source.stride {
            merged[targetChannel * stride + index] = source.words[sourceChannel * source.stride + index]
        }
        return Self(block: block, words: merged)
    }

    /// Match saved settings while allowing the firmware's documented precision
    /// and model-internal recalculation. Inactive channels remain bit-exact.
    public func matchesLoaded(_ actual: Self, channel: Int) -> Bool {
        guard isValid, actual.isValid, block == actual.block, words.count == actual.words.count,
              (0..<4).contains(channel) else { return false }
        for index in words.indices where words[index] != actual.words[index] {
            guard index / stride == channel else { return false }
            let parameter = index % stride
            if block == 58, [27, 45].contains(parameter) {
                // DISTORT_OFFSET1 and DISTORT_PI_RATIO are not editor controls.
                // Native desktop captures also change PI_RATIO after import.
                guard AM4AmpCatalog.shared.definition("58:\(parameter)") == nil,
                      actual.words[index] <= 65534 else { return false }
                continue
            }
            if block == 58, stride > 146, words[channel * stride + 146] == 1,
               [33, 34, 48, 50, 51, 107].contains(parameter) {
                // With Auto Speaker Impedance enabled, the saved curve/mode
                // controls these coefficients; firmware derives them from Cab.
                guard actual.words[index] <= 65534 else { return false }
                continue
            }
            if block == 62, stride > 76, [75, 76].contains(parameter),
               (words[channel * stride + 22] == 1 || words[channel * stride + 23] == 1) {
                // Blend is inactive while either mic is muted. Its stored
                // runtime pair is not an audible saved setting in that mode.
                let base = channel * stride
                guard actual.words[base + 75] <= 65534, actual.words[base + 76] <= 65534,
                      abs(Int(actual.words[base + 75]) + Int(actual.words[base + 76]) - 65534) <= 1 else { return false }
                continue
            }
            if block == 62, [75, 76].contains(parameter),
               let definition = AM4AmpCatalog.shared.definition("62:\(parameter)") {
                let position = Double(words[index]) / 65534
                let tolerance = definition.tolerance(at: position) * 65534
                if abs(Double(actual.words[index]) - Double(words[index])) <= tolerance { continue }
            }
            return false
        }
        return true
    }

    public var frames: [[UInt8]] {
        guard isValid else { return [] }
        func pair(_ value: Int) -> [UInt8] { [UInt8(value & 127), UInt8(value >> 7)] }
        var result = [AM4Message.request(function: 0x74, payload: pair(block) + pair(words.count))]
        for start in Swift.stride(from: 0, to: words.count, by: 256) {
            let chunk = words[start..<min(start + 256, words.count)]
            let raw = chunk.flatMap { value in [UInt8(value & 127), UInt8((value >> 7) & 127), UInt8((value >> 14) & 127)] }
            result.append(AM4Message.request(function: 0x75, payload: pair(chunk.count) + raw))
        }
        result.append(AM4Message.request(function: 0x76))
        return result
    }
}

public struct AM4EffectBankReader: Sendable {
    public let block: Int
    private var announced: Int?
    private var words: [UInt32] = []
    public private(set) var completed = false
    public private(set) var bank: AM4EffectBank?
    public init(block: Int) { self.block = block }

    public mutating func receive(_ message: AM4Message) {
        guard !completed else { return }
        let payload = message.payload
        if message.function == 0x74, payload.count == 4, Int(payload[0]) + Int(payload[1]) * 128 == block {
            announced = Int(payload[2]) + Int(payload[3]) * 128
            words = []
        } else if message.function == 0x75, let announced, payload.count >= 2 {
            let count = Int(payload[0]) + Int(payload[1]) * 128
            guard (1...256).contains(count), payload.count == 2 + count * 3, words.count + count <= announced else {
                completed = true; return
            }
            for offset in Swift.stride(from: 2, to: payload.count, by: 3) {
                words.append(UInt32(payload[offset]) | UInt32(payload[offset + 1]) << 7 | UInt32(payload[offset + 2]) << 14)
            }
        } else if message.function == 0x76, let announced {
            completed = true
            let result = AM4EffectBank(block: block, words: words)
            if payload.isEmpty, words.count == announced, result.isValid { bank = result }
        }
    }
}

extension AM4AmpBlockFile {
    public var banks: [AM4EffectBank] {
        dumps.compactMap { dump in
            var reader = AM4EffectBankReader(block: Int(dump[0].payload[0]))
            for message in dump { reader.receive(message) }
            return reader.bank
        }
    }
}
