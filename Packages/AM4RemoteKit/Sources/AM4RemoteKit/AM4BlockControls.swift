import Foundation

public struct AM4BlockContext: Codable, Equatable, Sendable {
    public let location: Int
    public let scene: Int
    public let blocks: [UInt32]
    public var isValid: Bool {
        (0..<104).contains(location) && (0..<4).contains(scene) && blocks.count == 4 &&
        blocks.allSatisfy { $0 < 0x4000 }
    }
}

public struct AM4BlockBypass: Codable, Equatable, Sendable, Identifiable {
    public let slot: Int
    public let type: UInt32
    public let bypassed: Bool
    public var id: Int { slot }
}

public struct AM4BlocksState: Codable, Equatable, Sendable {
    public let context: AM4BlockContext
    public let blocks: [AM4BlockBypass]
    public var isValid: Bool {
        context.isValid && blocks.count == context.blocks.filter({ $0 != 0 }).count &&
        Set(blocks.map(\.slot)).count == blocks.count && blocks.allSatisfy {
            (0..<4).contains($0.slot) && $0.type != 0 && context.blocks[$0.slot] == $0.type
        }
    }
    public func block(slot: Int, type: UInt32) -> AM4BlockBypass? {
        blocks.first { $0.slot == slot && $0.type == type }
    }
}

public struct AM4BlockBypassCommand: Codable, Sendable {
    public let context: AM4BlockContext
    public let slot: Int
    public let type: UInt32
    public let expectedBypassed: Bool
    public let bypassed: Bool
    public var isValid: Bool {
        context.isValid && (0..<4).contains(slot) && type != 0 && type < 0x4000 &&
        context.blocks[slot] == type && expectedBypassed != bypassed
    }
    public func isConfirmed(by state: AM4BlocksState) -> Bool {
        isValid && state.isValid && state.context == context && state.block(slot: slot, type: type)?.bypassed == bypassed
    }
}

extension AM4ParameterDefinition {
    public static func bypass(block type: UInt32) -> Self? {
        guard type > 0, type < 0x4000 else { return nil }
        return Self(key: "\(type):3", block: Int(type), parameter: 3, symbol: "BLOCK_BYPASS",
                    minimum: 0, maximum: 1, multiplier: 1, step: 0, typeCode: 224,
                    choices: ["ENGAGED", "BYPASSED"], dynamic: false)
    }
}

extension AM4Message {
    public func blockBypass(_ type: UInt32) -> Bool? {
        guard let definition = AM4ParameterDefinition.bypass(block: type),
              let value = parameterValue(definition),
              value.normalized == 0 || value.normalized == 1 else { return nil }
        return value.normalized == 1
    }
    public static func blockBypassWrite(_ command: AM4BlockBypassCommand) -> [UInt8]? {
        guard command.isValid, let definition = AM4ParameterDefinition.bypass(block: command.type) else { return nil }
        let bits = Float(command.bypassed ? 1 : 0).bitPattern
        let raw = (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
        return parameterFrame(definition, action: 1, raw: raw)
    }
}
