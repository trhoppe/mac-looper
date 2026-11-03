import Foundation

public struct AM4EffectsCatalog: Decodable, Sendable {
    public let version: Int
    public let effects: [AM4EffectDefinition]
    public static let shared: Self = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return try! JSONDecoder().decode(Self.self, from: Data(contentsOf: bundle.url(forResource: "EffectsCatalog", withExtension: "json")!))
    }()
    public static func canonical(_ block: Int) -> Int { block == 119 ? 118 : block }
    public func effect(_ block: Int) -> AM4EffectDefinition? { effects.first { $0.block == Self.canonical(block) } }
}

public struct AM4EffectDefinition: Decodable, Sendable {
    public let block: Int
    public let name: String
    public let typeKey: String
    public var typeParameter: Int { Int(typeKey.split(separator: ":").last!)! }
    public let models: [String]
    public let parameters: [AM4ParameterDefinition]
    public let pages: [AM4AmpPage]
    public func definition(_ key: String, addressedTo target: Int? = nil) -> AM4ParameterDefinition? {
        guard let item = parameters.first(where: { $0.key == key }) else { return nil }
        return target.map { item.addressedTo($0) } ?? item
    }
    public func page(_ id: String) -> AM4AmpPage? { pages.first { $0.id == id } }
    public func controls(page id: String, values: [String: AM4ParameterValue]) -> [AM4AmpControl] {
        var seen = Set<String>()
        return (page(id)?.controls ?? []).filter {
            $0.conditions.allSatisfy { $0.matches(values) } && seen.insert($0.key).inserted
        }
    }
    public func locked(_ control: AM4AmpControl, values: [String: AM4ParameterValue]) -> Bool {
        control.lockKey.map { values[$0]?.raw != 0 } ?? false
    }
    public func usesSwitch(_ control: AM4AmpControl, values: [String: AM4ParameterValue]) -> Bool {
        guard let definition = definition(control.key), definition.isDiscrete else { return false }
        if control.isSwitch == true || definition.typeCode == 224 { return true }
        if definition.dynamic {
            return controls(page: name, values: values).contains { $0.key == control.key && $0.isSwitch == true }
        }
        let choices = definition.choices.map { $0.uppercased() }
        return choices == ["OFF", "ON"] || choices == ["ENGAGED", "BYPASSED"]
    }
}

extension AM4ParameterDefinition {
    public func addressedTo(_ target: Int) -> Self {
        Self(key: key, block: target, parameter: parameter, symbol: symbol, minimum: minimum,
             maximum: maximum, multiplier: multiplier, step: step, typeCode: typeCode, choices: choices, dynamic: dynamic)
    }
}

public struct AM4EffectContext: Codable, Equatable, Sendable {
    public let location: Int
    public let scene: Int
    public let blocks: [UInt32]
    public let slot: Int
    public let block: Int
    public let channel: Int
    public var isValid: Bool {
        (0..<104).contains(location) && (0..<4).contains(scene) && blocks.count == 4 &&
        (0..<4).contains(slot) && (0..<4).contains(channel) &&
        AM4EffectsCatalog.shared.effect(block) != nil && blocks[slot] == UInt32(block) &&
        blocks.filter { $0 == UInt32(block) }.count == 1
    }
}

public struct AM4EffectControls: Codable, Equatable, Sendable {
    public let context: AM4EffectContext
    public let model: Int
    public let modelName: String
    public let page: String
    public let values: [String: AM4ParameterValue]
    public var isValid: Bool {
        guard context.isValid, let effect = AM4EffectsCatalog.shared.effect(context.block),
              effect.models.indices.contains(model), modelName.count <= 32, effect.page(page) != nil,
              values.count <= 160, values[effect.typeKey]?.raw == UInt32(model) else { return false }
        return values.allSatisfy { effect.definition($0.key)?.accepts($0.value) == true }
    }
}

public struct AM4EffectEdit: Codable, Sendable {
    public let state: AM4EffectControls
    public let key: String
    public let expected: AM4ParameterValue
    public var normalized: Double? = nil
    public var ordinal: Int? = nil
    public var direction: Int? = nil
    public var resetToDefault: Bool? = nil
    public var isValid: Bool {
        guard state.isValid, let effect = AM4EffectsCatalog.shared.effect(state.context.block),
              let definition = effect.definition(key), definition.accepts(expected),
              let control = effect.controls(page: state.page, values: state.values).first(where: { $0.key == key }),
              !effect.locked(control, values: state.values),
              [normalized != nil, ordinal != nil, direction != nil, resetToDefault == true].filter({ $0 }).count == 1 else { return false }
        if resetToDefault == true { return !definition.isDiscrete }
        if let normalized { return !definition.isDiscrete && normalized.isFinite && (0...1).contains(normalized) }
        if let ordinal { return definition.isDiscrete && !definition.dynamic && (0..<max(2, definition.choices.count)).contains(ordinal) }
        return definition.isDiscrete && direction.map { $0 == -1 || $0 == 1 } == true
    }
    public func confirmed(_ actual: AM4ParameterValue, reset: AM4ParameterValue?) -> Bool {
        guard isValid, let definition = AM4EffectsCatalog.shared.effect(state.context.block)?.definition(key) else { return false }
        if resetToDefault == true { return reset?.matches(actual) == true }
        if let normalized { return abs(actual.normalized - normalized) <= definition.tolerance(at: normalized) }
        if let ordinal { return definition.ordinal(actual) == ordinal }
        let change = definition.ordinal(actual) - definition.ordinal(expected)
        return change == direction || change == 0
    }
    public var frame: [UInt8]? {
        guard isValid, let definition = AM4EffectsCatalog.shared.effect(state.context.block)?.definition(key, addressedTo: state.context.block) else { return nil }
        if resetToDefault == true { return AM4Message.parameterFrame(definition, action: 8, raw: [0, 0, 0, 0]) }
        if let direction { return AM4Message.parameterFrame(definition, action: direction > 0 ? 3 : 5) }
        let bits = Float(normalized ?? Double(ordinal!)).bitPattern
        return AM4Message.parameterFrame(definition, action: normalized == nil ? 1 : 2,
            raw: (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) })
    }
}

public struct AM4EffectSelection: Codable, Sendable {
    public let state: AM4EffectControls
    public var model: Int? = nil
    public var libraryID: String? = nil
    public var channel: Int? = nil
    public var isValid: Bool {
        guard state.isValid, let effect = AM4EffectsCatalog.shared.effect(state.context.block),
              [model != nil, libraryID != nil, channel != nil].filter({ $0 }).count == 1 else { return false }
        if let model { return effect.models.indices.contains(model) }
        if let channel { return (0..<4).contains(channel) }
        return AM4EffectsLibrary.shared.entries.contains { $0.id == libraryID && $0.block == effect.block }
    }
}

public struct AM4EffectPageSelection: Codable, Sendable {
    public let slot: Int
    public let block: Int
    public let page: String?
    public var isValid: Bool {
        guard (0..<4).contains(slot), let effect = AM4EffectsCatalog.shared.effect(block) else { return false }
        return page == nil || effect.page(page!) != nil
    }
}

extension AM4Message {
    public static func effectChannelRequest(_ block: Int) -> [UInt8] {
        request(function: 1, payload: [UInt8(block), 0, 82, 15, 13, 0, 0, 0, 0, 0])
    }
    public func isEffectChannelReply(_ block: Int) -> Bool {
        function == 1 && payload.count == 56 && Array(payload.prefix(10)) == [UInt8(block), 0, 82, 15, 13, 0, 0, 0, 40, 0]
    }
    public func effectChannel(_ block: Int) -> Int? {
        guard isEffectChannelReply(block), let bytes = Self.unpack(Array(payload.dropFirst(10)), count: 40) else { return nil }
        let index = (0..<4).reduce(0) { $0 | Int(bytes[4 + $1]) << ($1 * 8) }
        return (0..<4).contains(index) && bytes[8] == 65 + index && bytes[9] == 0 ? index : nil
    }
    public static func effectValueWrite(block: Int, parameter: Int, value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return request(function: 1, payload: [UInt8(block), 0, UInt8(parameter & 127), UInt8(parameter >> 7), 1, 0, 0, 0, 4, 0] + pack((0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }))
    }
}

public struct AM4EffectsLibrary: Decodable, Sendable {
    public let version: Int
    public let entries: [AM4EffectLibraryEntry]
    public static let shared: Self = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        let value = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: bundle.url(forResource: "EffectsLibrary", withExtension: "json")!))
        precondition(value.entries.allSatisfy { $0.parsed != nil }, "Invalid effects library")
        return value
    }()
}

public struct AM4EffectLibraryEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let file: Data
    public let block: Int
    public var parsed: AM4EffectLibraryFile? {
        guard let result = AM4EffectLibraryFile(data: file, block: block), result.name == name, result.id == id else { return nil }
        return result
    }
}

/// VP4 and AM4 native block libraries share parameter IDs and the bank format
/// for the supported effects. Old files have fewer trailing parameters; never
/// shift existing IDs or interpret an unrelated device's preset as a block.
public struct AM4EffectLibraryFile: Sendable {
    public let id: String
    public let name: String
    public let sourceChannel: Int
    public let allChannels: Bool
    public let bank: AM4EffectBank
    public init?(data: Data, block: Int) {
        let bytes = [UInt8](data)
        guard (64...32_768).contains(bytes.count), let effect = AM4EffectsCatalog.shared.effect(block), effect.block == block else { return nil }
        func integer(_ offset: Int, _ size: Int) -> Int? {
            guard offset >= 0, offset + size <= bytes.count else { return nil }
            return (0..<size).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        guard let version = integer(0, 2), [3, 5].contains(version), let device = integer(2, 2), [20, 21].contains(device),
              integer(22, 4) == (block - 18) / 4,
              let scope = integer(26, 4), [0, 1].contains(scope),
              let channel = integer(30, 4), (0..<4).contains(channel),
              let length = integer(34, 4), (1...128).contains(length), 38 + length + 8 <= bytes.count,
              let name = String(bytes: bytes[38..<38 + length], encoding: .utf8), !name.contains("\0") else { return nil }
        var offset = 38 + length
        guard integer(offset, 4) == 0 else { return nil }
        offset += 4
        if version == 5 { guard integer(offset, 4) == 1 else { return nil }; offset += 4 }
        guard let size = integer(offset, 4), size >= 20, offset + 4 + size <= bytes.count else { return nil }
        offset += 4
        let end = offset + size
        var reader = AM4EffectBankReader(block: block)
        while offset < end {
            guard let stop = bytes[offset..<end].firstIndex(of: 0xF7) else { return nil }
            let frame = Array(bytes[offset...stop])
            guard frame.count >= 8, Array(frame.prefix(4)) == [240, 0, 1, 116], frame[4] == device,
                  frame.dropFirst().dropLast().allSatisfy({ $0 < 128 }),
                  AM4Message.checksum(Array(frame.dropLast(2))) == frame[frame.count - 2],
                  [0x74, 0x75, 0x76].contains(frame[5]) else { return nil }
            let normalized = AM4Message.request(function: frame[5], payload: Array(frame.dropFirst(6).dropLast(2)))
            reader.receive(AM4Message(bytes: normalized)!)
            offset = stop + 1
        }
        guard reader.completed, let bank = reader.bank, bank.stride > effect.typeParameter,
              (0..<4).allSatisfy({ effect.models.indices.contains(Int(bank.words[$0 * bank.stride + effect.typeParameter])) }) else { return nil }
        self.id = bytes[6..<22].map { String(format: "%02x", $0) }.joined()
        self.name = name; self.sourceChannel = channel; self.allChannels = scope == 0; self.bank = bank
    }
}

extension AM4EffectBank {
    public func mergingEffectLibrary(_ file: AM4EffectLibraryFile, channel: Int) -> Self? {
        guard isValid, file.bank.isValid, AM4EffectsCatalog.canonical(block) == file.bank.block,
              file.bank.stride <= stride, stride - file.bank.stride <= 3, (0..<4).contains(channel) else { return nil }
        var output = words
        for target in file.allChannels ? Array(0..<4) : [channel] {
            let source = file.allChannels ? target : file.sourceChannel
            for index in 0..<file.bank.stride { output[target * stride + index] = file.bank.words[source * file.bank.stride + index] }
        }
        return Self(block: block, words: output)
    }
    public func matchesEffect(_ actual: Self, channel: Int, allChannels: Bool) -> Bool {
        guard isValid, actual.isValid, block == actual.block, words.count == actual.words.count,
              let effect = AM4EffectsCatalog.shared.effect(block), (0..<4).contains(channel) else { return false }
        for ch in 0..<4 {
            let base = ch * stride
            let values = Dictionary(uniqueKeysWithValues: effect.parameters.filter { $0.parameter < stride }.map {
                let raw = actual.words[base + $0.parameter]
                return ($0.key, AM4ParameterValue(raw: raw, normalized: Double(raw) / 65534, text: ""))
            })
            let controls = effect.pages.flatMap { effect.controls(page: $0.id, values: values) }
            let locked = Set(controls.filter { effect.locked($0, values: values) }.map(\.key))
            if !allChannels && ch != channel {
                for index in 0..<stride where words[base + index] != actual.words[base + index] {
                    if locked.contains("\(effect.block):\(index)") { continue }
                    return false
                }
                continue
            }
            guard effect.typeParameter < stride, words[base + effect.typeParameter] == actual.words[base + effect.typeParameter],
                  Array(words[base..<base + 10]) == Array(actual.words[base..<base + 10]) else { return false }
            // The serialized common header is not indexed like virtual common
            // parameter IDs (notably bypass). Preserve its complete contents.
            for key in Set(controls.map(\.key)) where !locked.contains(key) {
                guard let definition = effect.definition(key), definition.parameter < stride else { return false }
                if definition.parameter < 10 { continue }
                let wanted = words[base + definition.parameter], observed = actual.words[base + definition.parameter]
                if definition.isDiscrete { if wanted != observed { return false } }
                else if abs(Double(wanted) - Double(observed)) > definition.tolerance(at: Double(wanted) / 65534) * 65534 { return false }
            }
        }
        return true
    }
}
