import Foundation

/// Factual parameter metadata, separate from the app's own native layout.
public struct AM4AmpCatalog: Decodable, Sendable {
    public let version: Int
    public let source: String
    public let models: [String]
    public let parameters: [AM4ParameterDefinition]
    public let pages: [AM4AmpPage]

    public static let shared: Self = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "AmpCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(Self.self, from: data) else {
            preconditionFailure("Missing or invalid Amp catalog")
        }
        return result
    }()

    public func definition(_ key: String) -> AM4ParameterDefinition? {
        parameters.first { $0.key == key }
    }

    public func page(_ id: String) -> AM4AmpPage? { pages.first { $0.id == id } }

    public func controls(page id: String, values: [String: AM4ParameterValue]) -> [AM4AmpControl] {
        var seen = Set<String>()
        return (page(id)?.controls ?? []).filter { control in
            guard control.conditions.allSatisfy({ $0.matches(values) }), !seen.contains(control.key) else { return false }
            seen.insert(control.key)
            return true
        }
    }

    /// Dynamic mode parameters may be switches on one amp and multi-choice
    /// selectors on another. Use the model's actual editor widget metadata.
    public func usesSwitch(_ control: AM4AmpControl, values: [String: AM4ParameterValue]) -> Bool {
        guard let definition = definition(control.key), definition.isDiscrete else { return false }
        if control.isSwitch == true || definition.typeCode == 224 { return true }
        if definition.dynamic {
            return controls(page: "Amp", values: values).contains { $0.key == control.key && $0.isSwitch == true }
        }
        let choices = definition.choices.map { $0.uppercased() }
        return choices == ["OFF", "ON"] || choices == ["ENGAGED", "BYPASSED"]
    }

    public var editableKeys: Set<String> { Set(pages.flatMap { $0.controls.map(\.key) }) }
}

public struct AM4AmpPage: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let controls: [AM4AmpControl]
}

public struct AM4AmpControl: Decodable, Identifiable, Sendable {
    public let id: String
    public let key: String
    public let label: String
    public let section: String
    public let conditions: [AM4AmpCondition]
    public let isSwitch: Bool?
    public var lockKey: String? = nil
}

public struct AM4AmpCondition: Decodable, Sendable {
    public let key: String
    public let values: [Int]
    public let negate: Bool
    public func matches(_ state: [String: AM4ParameterValue]) -> Bool {
        guard let value = state[key] else { return false }
        return values.contains(Int(value.raw)) != negate
    }
}

public struct AM4ParameterDefinition: Decodable, Identifiable, Sendable {
    public let key: String
    public var id: String { key }
    public let block: Int
    public let parameter: Int
    public let symbol: String
    public let minimum: Double
    public let maximum: Double
    public let multiplier: Double
    public let step: Double
    public let typeCode: Int
    public let choices: [String]
    public let dynamic: Bool
    public var isDiscrete: Bool { !choices.isEmpty || typeCode == 224 }
    // Speaker impedance curves carry their stable table ID in the Float32
    // field (live capture: raw 36 / float 87 / “4x12 5153 Stealth”). Other
    // enums expose their ordinal in raw and a 0...1 position in the float.
    public var usesAbsoluteEnumValue: Bool { symbol == "DISTORT_SPKRMODEL" }
    public func ordinal(_ value: AM4ParameterValue) -> Int {
        usesAbsoluteEnumValue ? Int(value.normalized.rounded()) : Int(value.raw)
    }
    public func accepts(_ value: AM4ParameterValue) -> Bool {
        guard value.isValid else { return false }
        if usesAbsoluteEnumValue {
            return value.normalized == value.normalized.rounded() && (0..<choices.count).contains(Int(value.normalized))
        }
        // Captured AM4 Delay Expert reply: bypass mode "Mute FX In" has
        // raw=3 AND float=3, rather than a normalized float. Other firmware/
        // blocks also use the normalized form, so accept both bounded forms.
        if symbol == "BLOCK_BYPASSMODE", !dynamic, !choices.isEmpty,
           choices.indices.contains(Int(value.raw)), value.normalized == Double(value.raw) { return true }
        return (0...1).contains(value.normalized)
    }
    public var logarithmic: Bool { [4, 5].contains(typeCode >> 4) && minimum > 0 && maximum > minimum }
    public var unit: String {
        switch typeCode & 15 {
        case 1: return "dB"
        case 2: return "Hz"
        case 3: return "s"
        case 4: return "ms"
        case 5: return "%"
        case 6: return "°"
        case 8: return "pF"
        default: return ""
        }
    }
    public func displayValue(_ normalized: Double) -> Double {
        let value = logarithmic ? minimum * pow(maximum / minimum, normalized) : minimum + (maximum - minimum) * normalized
        return value * multiplier
    }
    public func normalizedValue(forDisplay value: Double) -> Double? {
        let epsilon = max(abs(minimum * multiplier), abs(maximum * multiplier)) * Double(Float.ulpOfOne) * 2
        guard !isDiscrete, value.isFinite, multiplier > 0,
              value >= minimum * multiplier - epsilon, value <= maximum * multiplier + epsilon else { return nil }
        var physical = value / multiplier
        if step > 0 { physical = minimum + ((physical - minimum) / step).rounded() * step }
        physical = min(maximum, max(minimum, physical))
        let position = logarithmic ? log(physical / minimum) / log(maximum / minimum)
            : (physical - minimum) / (maximum - minimum)
        return position.isFinite ? min(1, max(0, position)) : nil
    }
    public func position(afterDragging points: Double, from start: Double) -> Double {
        let position = min(1, max(0, start + points / 240))
        return normalizedValue(forDisplay: displayValue(position)) ?? position
    }
    public func preview(_ normalized: Double) -> String {
        let value = displayValue(normalized)
        let places = unit == "Hz" || unit == "pF" ? 1 : 2
        return String(format: "%.*f", places, value) + (unit.isEmpty ? "" : " " + unit)
    }
    /// Q16 read-back quantization plus half of one display increment.
    public func tolerance(at normalized: Double) -> Double {
        guard step > 0 else { return 3 / 65534 }
        if logarithmic {
            let value = displayValue(normalized) / multiplier
            let next = min(maximum, value + step / 2)
            return max(3 / 65534, abs(log(next / value) / log(maximum / minimum)))
        }
        return max(3 / 65534, step / (maximum - minimum) * 0.51)
    }
}

/// Long reads contain a raw ordinal/Q16 value, a normalized Float32, and a
/// 32-byte display string. The text comes from firmware, including units and
/// model-dependent option names; it is not a parameter range descriptor.
public struct AM4ParameterValue: Codable, Equatable, Sendable {
    public let raw: UInt32
    public let normalized: Double
    public let text: String
    public var isValid: Bool { normalized.isFinite && (0...16383).contains(normalized) && text.count <= 32 }
    public func matches(_ other: Self) -> Bool {
        raw == other.raw && abs(normalized - other.normalized) <= 1 / 65534 && text == other.text
    }
}

public struct AM4AmpControls: Codable, Equatable, Sendable {
    public let context: AM4AmpContext
    public let model: Int
    public let modelName: String
    public let page: String
    public let values: [String: AM4ParameterValue]
    public var isValid: Bool {
        context.isValid && (0..<AM4AmpCatalog.shared.models.count).contains(model) &&
        modelName.count <= 32 && AM4AmpCatalog.shared.page(page) != nil && values.count <= 200 &&
        values.allSatisfy { AM4AmpCatalog.shared.definition($0.key)?.accepts($0.value) == true } &&
        values["58:10"]?.raw == UInt32(model)
    }
}

public struct AM4AmpEdit: Codable, Sendable {
    public let context: AM4AmpContext
    public let model: Int
    public let page: String
    public let key: String
    public let expected: AM4ParameterValue
    /// Exactly one operation: continuous normalized value, discrete ordinal,
    /// or a single firmware increment/decrement for model-dependent options.
    public var normalized: Double? = nil
    public var ordinal: Int? = nil
    public var direction: Int? = nil
    public var resetToDefault: Bool? = nil

    public var isValid: Bool {
        let catalog = AM4AmpCatalog.shared
        guard context.isValid, (0..<catalog.models.count).contains(model),
              let definition = catalog.definition(key), catalog.editableKeys.contains(key),
              catalog.page(page)?.controls.contains(where: { $0.key == key }) == true,
              definition.accepts(expected),
              [normalized != nil, ordinal != nil, direction != nil, resetToDefault == true].filter({ $0 }).count == 1 else { return false }
        if resetToDefault == true { return !definition.isDiscrete }
        if let normalized { return !definition.isDiscrete && normalized.isFinite && (0...1).contains(normalized) }
        if let ordinal { return definition.isDiscrete && !definition.dynamic && (0..<max(2, definition.choices.count)).contains(ordinal) }
        return definition.isDiscrete && direction.map { $0 == -1 || $0 == 1 } == true
    }
    public func isConfirmed(by actual: AM4ParameterValue, resetResult: AM4ParameterValue? = nil) -> Bool {
        guard isValid, actual.isValid, let definition = AM4AmpCatalog.shared.definition(key) else { return false }
        if resetToDefault == true { return resetResult.map { definition.accepts($0) && $0.matches(actual) } ?? false }
        if let normalized { return abs(actual.normalized - normalized) <= definition.tolerance(at: normalized) }
        if let ordinal { return definition.ordinal(actual) == ordinal }
        let difference = definition.ordinal(actual) - definition.ordinal(expected)
        return difference == direction! || difference == 0
    }

}

extension AM4Message {
    public static func pack(_ raw: [UInt8]) -> [UInt8] {
        var packed: [UInt8] = [], accumulator: UInt32 = 0, remaining = 0
        for byte in raw {
            accumulator = (accumulator << 8) | UInt32(byte); remaining += 8
            while remaining >= 7 {
                remaining -= 7; packed.append(UInt8((accumulator >> remaining) & 0x7F))
            }
            accumulator &= (1 << remaining) - 1
        }
        if remaining > 0 { packed.append(UInt8(accumulator << (7 - remaining))) }
        return packed
    }
    public static func parameterRequest(_ definition: AM4ParameterDefinition) -> [UInt8] {
        parameterFrame(definition, action: 0x0D)
    }
    public static func parameterFrame(_ definition: AM4ParameterDefinition, action: Int, raw: [UInt8] = []) -> [UInt8] {
        func pair(_ n: Int) -> [UInt8] { [UInt8(n & 127), UInt8(n >> 7)] }
        return request(function: 1, payload: pair(definition.block) + pair(definition.parameter) + pair(action) + [0, 0] + pair(raw.count) + pack(raw))
    }
    public static func parameterWrite(_ edit: AM4AmpEdit) -> [UInt8]? {
        guard edit.isValid, let definition = AM4AmpCatalog.shared.definition(edit.key) else { return nil }
        if edit.resetToDefault == true { return parameterFrame(definition, action: 8, raw: [0, 0, 0, 0]) }
        if let direction = edit.direction { return parameterFrame(definition, action: direction > 0 ? 3 : 5) }
        // MESSAGE_SET_NORM (2) delegates continuous conversion to firmware;
        // MESSAGE_SET (1) takes an absolute ordinal for enum parameters.
        let value = Float(edit.normalized ?? Double(edit.ordinal!))
        let raw = (0..<4).map { UInt8((value.bitPattern >> ($0 * 8)) & 255) }
        return parameterFrame(definition, action: edit.normalized == nil ? 1 : 2, raw: raw)
    }
    public func isParameterResponse(_ definition: AM4ParameterDefinition, action: Int = 13) -> Bool {
        [8, 13].contains(action) && function == 1 && payload.count == 56 &&
        Array(payload.prefix(10)) == [UInt8(definition.block & 127), UInt8(definition.block >> 7),
            UInt8(definition.parameter & 127), UInt8(definition.parameter >> 7), UInt8(action), 0, 0, 0, 40, 0]
    }
    public func parameterValue(_ definition: AM4ParameterDefinition, action: Int = 13) -> AM4ParameterValue? {
        guard isParameterResponse(definition, action: action),
              let raw = Self.unpack(Array(payload.dropFirst(10)), count: 40),
              let end = raw[8...].firstIndex(of: 0),
              let text = String(bytes: raw[8..<end], encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { return nil }
        func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | (UInt32(raw[offset + $1]) << ($1 * 8)) } }
        // The position occupies the low UInt16. Captured editor polling
        // leaves the upper half as changing padding; never compare it.
        let value = AM4ParameterValue(raw: u32(0) & 0xFFFF, normalized: Double(Float(bitPattern: u32(4))), text: text)
        return definition.accepts(value) ? value : nil
    }
}

/// A preset target is global. A scene target belongs to the preset shown
/// when the user taps it, so scene commands carry that expected location.
public struct AM4NavigationCommand: Codable, Sendable {
    public var preset: Int? = nil
    public var scene: Int? = nil
    public let expectedLocation: Int
    public var isValid: Bool {
        (0..<104).contains(expectedLocation) &&
        [preset != nil, scene != nil].filter({ $0 }).count == 1 &&
        (preset == nil || (0..<104).contains(preset!)) &&
        (scene == nil || (0..<4).contains(scene!))
    }
    public func isConfirmed(location: Int, scene: Int) -> Bool {
        guard isValid, (0..<104).contains(location), (0..<4).contains(scene) else { return false }
        if let preset { return location == preset }
        return location == expectedLocation && scene == self.scene
    }

}

extension AM4Message {
    public static func navigationWrite(_ command: AM4NavigationCommand) -> [UInt8]? {
        guard command.isValid else { return nil }
        // AM4 uses Float32 for preset indices, UInt32 for scene indices.
        let bits = command.preset.map { Float($0).bitPattern } ?? UInt32(command.scene!)
        let raw = (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
        return request(function: 1, payload: [78, 1, command.preset == nil ? 13 : 10, 0, 1, 0, 0, 0, 4, 0] + pack(raw))
    }
}
