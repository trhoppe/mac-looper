import Foundation

/// AM4-specific SysEx, deliberately separate from Core MIDI and the interface.
public struct AM4Message: Equatable, Sendable {
    public let function: UInt8
    public let payload: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 8,
              Array(bytes.prefix(5)) == [0xF0, 0x00, 0x01, 0x74, 0x15],
              bytes.last == 0xF7,
              bytes[5..<(bytes.count - 1)].allSatisfy({ $0 < 0x80 }),
              Self.checksum(Array(bytes.dropLast(2))) == bytes[bytes.count - 2]
        else { return nil }
        function = bytes[5]
        payload = Array(bytes.dropFirst(6).dropLast(2))
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0, ^) & 0x7F
    }

    public static func request(function: UInt8, payload: [UInt8] = []) -> [UInt8] {
        precondition(function < 0x80 && payload.allSatisfy { $0 < 0x80 })
        let body: [UInt8] = [0xF0, 0x00, 0x01, 0x74, 0x15, function] + payload
        return body + [checksum(body), 0xF7]
    }

    public static var firmwareRequest: [UInt8] { request(function: 0x08) }
    public static var locationRequest: [UInt8] {
        request(function: 0x01, payload: [0x4E, 1, 0x0A, 0, 0x0E, 0, 0, 0, 0, 0])
    }
    public static var disconnectRequest: [UInt8] { request(function: 0x42) }

    public static var ampGainRequest: [UInt8] {
        request(function: 1, payload: [0x3A, 0, 0x0B, 0, 0x0E, 0, 0, 0, 0, 0])
    }

    public static func ampGainWrite(_ gain: Double) -> [UInt8]? {
        guard gain.isFinite, (0...10).contains(gain) else { return nil }
        let bits = Float(gain / 10).bitPattern
        let raw = (0..<4).map { UInt8((bits >> ($0 * 8)) & 0xFF) }
        var packed: [UInt8] = []
        var accumulator: UInt32 = 0
        var remaining = 0
        for byte in raw {
            accumulator = (accumulator << 8) | UInt32(byte)
            remaining += 8
            while remaining >= 7 {
                remaining -= 7
                packed.append(UInt8((accumulator >> remaining) & 0x7F))
            }
            accumulator &= (1 << remaining) - 1
        }
        if remaining > 0 { packed.append(UInt8(accumulator << (7 - remaining))) }
        return request(function: 1, payload: [0x3A, 0, 0x0B, 0, 1, 0, 0, 0, 4, 0] + packed)
    }

    public var ampGain: Double? {
        guard function == 1, payload.count == 15,
              Array(payload.prefix(10)) == [0x3A, 0, 0x0B, 0, 0x0E, 0, 0, 0, 4, 0],
              let raw = Self.unpack(Array(payload.dropFirst(10)), count: 4)
        else { return nil }
        let value = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(raw[$1]) << ($1 * 8)) }
        guard value <= 65534 else { return nil }
        return Double(value) * 10 / 65534
    }

    /// Read a stored name without loading that preset into the edit buffer.
    public static func storedPresetNameRequest(_ location: Int) -> [UInt8]? {
        guard (0..<104).contains(location) else { return nil }
        let index: [UInt8] = [UInt8(location >> 1), UInt8((location & 1) << 6), 0, 0, 0]
        return request(function: 0x01, payload:
            [0x4E, 0x01, 0x0B, 0, 0x12, 0, 0, 0, 4, 0] + index)
    }

    public var storedPresetName: String? {
        guard function == 0x01, payload.count == 47,
              Array(payload.prefix(10)) == [0x4E, 1, 0x0B, 0, 0x12, 0, 0, 0, 0x20, 0],
              let raw = Self.unpack(Array(payload.dropFirst(10)), count: 32),
              let terminator = raw.firstIndex(of: 0),
              raw[..<terminator].allSatisfy({ $0 >= 32 && $0 < 127 }),
              let name = String(bytes: raw[..<terminator], encoding: .ascii)
        else { return nil }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Read the edit buffer's 192-byte preset/scene/slot table. No navigation.
    public static var snapshotRequest: [UInt8] {
        request(function: 0x01, payload: [0x4E, 0x01, 0, 0, 0x1F, 0, 0, 0, 0, 0])
    }

    public var location: Int? {
        // The legacy 0x14 reply can stay at zero while another preset is
        // active. Read the PATCH current-location register instead.
        guard function == 0x01, payload.count == 15,
              Array(payload.prefix(10)) == [0x4E, 1, 0x0A, 0, 0x0E, 0, 0, 0, 4, 0],
              let raw = Self.unpack(Array(payload.dropFirst(10)), count: 4)
        else { return nil }
        let result = (0..<4).reduce(0) { $0 | (Int(raw[$1]) << ($1 * 8)) }
        return (0..<104).contains(result) ? result : nil
    }

    /// Decode the continuous MSB-first stream, rather than MIDI's alternate
    /// seven-data-bytes-plus-high-bit-mask format.
    public static func unpack(_ bytes: [UInt8], count: Int) -> [UInt8]? {
        guard count >= 0, count <= 65_536,
              bytes.count == (count * 8 + 6) / 7,
              bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        var result: [UInt8] = []
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 7) | UInt32(byte)
            bits += 7
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((accumulator >> bits) & 0xFF))
                accumulator &= (1 << bits) - 1
            }
        }
        guard result.count == count, accumulator == 0 else { return nil }
        return result
    }

    public var snapshot: AM4Snapshot? {
        guard function == 0x01, payload.count == 230,
              Array(payload.prefix(10)) == [0x4E, 0x01, 0, 0, 0x1F, 0, 0, 0, 0x40, 0x01],
              let raw = Self.unpack(Array(payload.dropFirst(10)), count: 192)
        else { return nil }

        func uint32(at offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | (UInt32(raw[offset + $1]) << ($1 * 8)) }
        }
        func name(at offset: Int) -> String {
            let characters = raw[offset..<(offset + 32)]
                .prefix(while: { $0 != 0 }).filter { $0 >= 32 && $0 < 127 }
            return String(bytes: characters, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        let scene = uint32(at: 8)
        guard scene < 4 else { return nil }
        return AM4Snapshot(
            name: name(at: 16), scene: Int(scene),
            sceneNames: (0..<4).map { name(at: 48 + $0 * 32) },
            blockIDs: (0..<4).map { uint32(at: 176 + $0 * 4) },
            edited: payload[15] & 0x04 != 0
        )
    }

    public static func locationLabel(_ index: Int) -> String {
        guard (0..<104).contains(index) else { return "—" }
        let bank = Character(UnicodeScalar(65 + index / 4)!)
        return "\(bank)\(index % 4 + 1)"
    }
}

public struct AM4Snapshot: Equatable, Sendable, Codable {
    public let name: String
    public let scene: Int
    public let sceneNames: [String]
    public let blockIDs: [UInt32]
    public var edited: Bool? = nil
}

public struct AM4Preset: Identifiable, Equatable, Sendable, Codable {
    public let id: Int
    public let name: String
    public var isEmpty: Bool { name == "<EMPTY>" || name.isEmpty }
}

public struct AM4AmpContext: Codable, Equatable, Sendable {
    public let location: Int
    public let scene: Int
    public let blocks: [UInt32]
    public var channel: Int? = nil
    public var isValid: Bool {
        (0..<104).contains(location) && (0..<4).contains(scene) && blocks.count == 4 && blocks.contains(0x3A) && (channel == nil || (0..<4).contains(channel!))
    }
}

public struct AM4AmpState: Codable, Equatable, Sendable {
    public let context: AM4AmpContext
    public let gain: Double
    public var isValid: Bool { context.isValid && gain.isFinite && (0...10).contains(gain) }

    public func matches(_ expected: Self) -> Bool {
        context == expected.context && abs(gain - expected.gain) <= 0.005
    }
}

public struct AM4GainCommand: Codable, Sendable {
    public let expected: AM4AmpState
    public let gain: Double
    public var isValid: Bool { expected.isValid && gain.isFinite && (0...10).contains(gain) }
}

public struct AM4ControlError: Codable { public let message: String }

/// State shared by the local Mac helper and the simulator.
public struct AM4DeviceState: Codable, Sendable {
    public let version: Int
    public let status: String
    public let connected: Bool
    public let loadingPresets: Bool
    public let location: Int?
    public let snapshot: AM4Snapshot?
    public let presets: [AM4Preset]
    public var amp: AM4AmpState? = nil
    public var ampControls: AM4AmpControls? = nil
    public var effectControls: AM4EffectControls? = nil
    public var effectResetValue: AM4ParameterValue? = nil
    public var ampResetValue: AM4ParameterValue? = nil
    public var blocks: AM4BlocksState? = nil
    public var blockStatus: String = ""
    public var usbPlayback: AM4USBPlaybackLevel? = nil
    public var usbPlaybackStatus: String = ""
    public var navigationStatus: String = ""
    public var navigationBusy: Bool = false
    public var gainStatus: String = ""
    public var gainBusy: Bool = false
    public var presetEdited: Bool? = nil
    public var presetSaveSupported: Bool? = nil
    public var presetSaveBusy: Bool? = nil
    public var presetSaveStatus: String? = nil

    public var isValid: Bool {
        version == 9 && presets.count <= 104 &&
        presets.allSatisfy { (0..<104).contains($0.id) && $0.name.count <= 32 } &&
        Set(presets.map(\.id)).count == presets.count &&
        (location == nil || (0..<104).contains(location!)) &&
        (snapshot == nil || ((0..<4).contains(snapshot!.scene) &&
                            snapshot!.sceneNames.count == 4 && snapshot!.blockIDs.count == 4)) &&
        (usbPlayback == nil || usbPlayback!.isValid) &&
        (blocks == nil || (blocks!.isValid && blocks!.context.location == location &&
             blocks!.context.scene == snapshot?.scene && blocks!.context.blocks == snapshot?.blockIDs)) &&
        (effectResetValue == nil || effectResetValue!.isValid) &&
        (effectControls == nil || (effectControls!.isValid && effectControls!.context.location == location &&
            effectControls!.context.scene == snapshot?.scene && effectControls!.context.blocks == snapshot?.blockIDs)) &&
        (ampResetValue == nil || ampResetValue!.isValid) &&
        (ampControls == nil || (ampControls!.isValid && ampControls!.context.location == location &&
             ampControls!.context.scene == snapshot?.scene && ampControls!.context.blocks == snapshot?.blockIDs)) &&
        (amp == nil || (amp!.isValid && amp!.context.location == location &&
                       amp!.context.scene == snapshot?.scene && amp!.context.blocks == snapshot?.blockIDs))
    }
}

/// Name replies omit their slot number. Keep exactly one request outstanding;
/// abort on timeout rather than guessing which slot a late reply belongs to.
public struct AM4PresetCatalog: Sendable {
    public private(set) var presets: [AM4Preset] = []
    public private(set) var pendingLocation: Int?
    public var isComplete: Bool { presets.count == 104 }
    public init() {}

    public mutating func start() -> [UInt8] {
        presets = []
        pendingLocation = 0
        return AM4Message.storedPresetNameRequest(0)!
    }

    public mutating func receive(_ message: AM4Message) -> [UInt8]? {
        guard let index = pendingLocation, let name = message.storedPresetName else { return nil }
        presets.append(AM4Preset(id: index, name: name))
        pendingLocation = index < 103 ? index + 1 : nil
        return pendingLocation.flatMap(AM4Message.storedPresetNameRequest)
    }

    public mutating func cancel() { pendingLocation = nil }
}

/// Receives split SysEx frames, skips interleaved real-time events, and drops
/// malformed/oversized frames without letting memory grow indefinitely.
public struct SysExStream: Sendable {
    private var pending: [UInt8] = []
    public init() {}

    public mutating func receive(_ bytes: [UInt8]) -> [AM4Message] {
        var messages: [AM4Message] = []
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if byte == 0xF0 { pending = [byte]; continue }
            guard !pending.isEmpty else { continue }
            if byte == 0xF7 {
                pending.append(byte)
                if let message = AM4Message(bytes: pending) { messages.append(message) }
                pending.removeAll(keepingCapacity: true)
            } else if byte >= 0x80 || pending.count >= 65_536 {
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return messages
    }
}


/// Saving is limited to the exact preset/scene/layout displayed when clicked.
public struct AM4PresetSaveCommand: Codable, Equatable, Sendable {
    public let location: Int
    public let snapshot: AM4Snapshot
    public var isValid: Bool {
        (0..<104).contains(location) && (0..<4).contains(snapshot.scene) && snapshot.sceneNames.count == 4 &&
        snapshot.blockIDs.count == 4 && snapshot.blockIDs.allSatisfy { $0 < 0x4000 } && snapshot.name.count <= 32
    }
    public func matches(location: Int, snapshot: AM4Snapshot) -> Bool {
        isValid && self.location == location && self.snapshot.name == snapshot.name &&
        self.snapshot.scene == snapshot.scene && self.snapshot.sceneNames == snapshot.sceneNames && self.snapshot.blockIDs == snapshot.blockIDs
    }
}

extension AM4Message {
    /// AM4-Edit's SAVE_TO_LOCATION: uint32 LE slot, not a Float32 or bank/PC.
    /// Wire evidence: TheAndrewStaker/mcp-midi-control, am4/setParam.ts,
    /// session-18-save-preset-z04 capture. Only the current slot is used by the UI.
    public static func savePresetWrite(_ command: AM4PresetSaveCommand) -> [UInt8]? {
        guard command.isValid else { return nil }
        let slot = UInt32(command.location)
        return request(function: 1, payload: [0, 0, 0, 0, 0x1B, 0, 0, 0, 4, 0] + pack((0..<4).map { UInt8((slot >> ($0 * 8)) & 255) }))
    }
    /// An addressing-only 18-byte acknowledgement; a reflected 23-byte write
    /// or a parameter descriptor must never count as a completed save.
    public var acknowledgesPresetSave: Bool {
        function == 1 && payload == [0, 0, 0, 0, 0x1B, 0, 0, 0, 0, 0]
    }
    public var editsPreset: Bool {
        if function == 0x75 { return true } // Working block library data.
        guard function == 1, payload.count >= 10 else { return false }
        let block = Int(payload[0]) | Int(payload[1]) << 7
        let parameter = Int(payload[2]) | Int(payload[3]) << 7
        let action = Int(payload[4]) | Int(payload[5]) << 7
        // Global USB playback level and loading a different preset are not edits.
        return block > 1 && !(block == 206 && parameter == 10) && [1, 2, 3, 5, 8].contains(action)
    }
}
