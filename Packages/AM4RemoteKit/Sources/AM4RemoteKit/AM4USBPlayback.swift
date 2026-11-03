import Foundation

/// Global USB 1/2 playback gain: GLOBAL_USBLEVEL1, not a preset parameter.
public struct AM4USBPlaybackLevel: Codable, Equatable, Sendable {
    public static let minimum = -40.0
    public static let maximum = 20.0
    public static let tolerance = 0.011
    public let decibels: Double
    public let text: String
    public var isValid: Bool {
        decibels.isFinite && (Self.minimum...Self.maximum).contains(decibels) && text.count <= 32
    }
    public func matches(_ other: Self) -> Bool {
        isValid && other.isValid && abs(decibels - other.decibels) <= Self.tolerance
    }
}

public struct AM4USBPlaybackCommand: Codable, Sendable {
    public let expected: AM4USBPlaybackLevel
    public let decibels: Double
    public var isValid: Bool {
        expected.isValid && decibels.isFinite &&
        (AM4USBPlaybackLevel.minimum...AM4USBPlaybackLevel.maximum).contains(decibels)
    }
    public func isConfirmed(by value: AM4USBPlaybackLevel) -> Bool {
        isValid && value.isValid && abs(value.decibels - decibels) <= AM4USBPlaybackLevel.tolerance
    }
}

extension AM4Message {
    public static var usbPlaybackRequest: [UInt8] {
        request(function: 1, payload: [1, 0, 99, 0, 13, 0, 0, 0, 0, 0])
    }
    public var isUSBPlaybackReply: Bool {
        function == 1 && payload.count == 56 && Array(payload.prefix(10)) == [1, 0, 99, 0, 13, 0, 0, 0, 40, 0]
    }
    public var usbPlaybackLevel: AM4USBPlaybackLevel? {
        guard isUSBPlaybackReply,
              let raw = Self.unpack(Array(payload.dropFirst(10)), count: 40),
              let end = raw[8...].firstIndex(of: 0),
              let text = String(bytes: raw[8..<end], encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { return nil }
        // Firmware's formatted dB value avoids assuming that this global
        // gain control shares an Amp knob's normalized Float32 read format.
        var number = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")
        if number.lowercased().hasSuffix("db") { number = String(number.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        let decibels: Double?
        if ["-INF", "-INFINITY", "-∞"].contains(number.uppercased()) {
            decibels = AM4USBPlaybackLevel.minimum
        } else { decibels = Double(number) }
        guard let decibels else { return nil }
        let level = AM4USBPlaybackLevel(decibels: decibels, text: text)
        return level.isValid ? level : nil
    }
    public static func usbPlaybackWrite(_ command: AM4USBPlaybackCommand) -> [UInt8]? {
        guard command.isValid else { return nil }
        // Captured AM4-Edit writes carry absolute dB as Float32, action 1.
        let bits = Float(command.decibels).bitPattern
        let raw = (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
        return request(function: 1, payload: [1, 0, 99, 0, 1, 0, 0, 0, 4, 0] + pack(raw))
    }
}
