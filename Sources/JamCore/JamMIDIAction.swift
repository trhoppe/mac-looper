/// Fixed pedal assignments. Zero-value CC releases never trigger a transport.
public enum JamMIDIAction: UInt8, Equatable, Sendable, CaseIterable {
    case arm = 22, record, playStop, clear, drummer

    public static func decode<C: RandomAccessCollection>(_ words: C) -> [Self] where C.Element == UInt32 {
        // UMP length in 32-bit words, including reserved message types.
        let lengths = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        var offset = 0, actions: [Self] = []
        while offset < words.count {
            let word = words[words.index(words.startIndex, offsetBy: offset)]
            let type = Int(word >> 28), count = lengths[type]
            guard count <= words.count - offset else { break }
            // CoreMIDI delivers MIDI 1.0 UMP (and translates MIDI 2.0 sources).
            // Any group/channel is accepted; notes, SysEx, clock, and other CCs are ignored.
            if type == 2, (word >> 20) & 0xF == 0xB {
                let controller = UInt8((word >> 8) & 0xFF), value = UInt8(word & 0xFF)
                if value > 0, value < 128, let action = Self(rawValue: controller) { actions.append(action) }
            }
            offset += count
        }
        return actions
    }
}
