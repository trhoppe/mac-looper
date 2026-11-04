import XCTest
import JamCore

final class JamMIDIActionTests: XCTestCase {
    func testAssignmentsAcceptAllChannelsAndGroupsButIgnoreZeroReleases() {
        for channel: UInt32 in 0..<16 {
            for group: UInt32 in 0..<16 {
                for action in JamMIDIAction.allCases {
                    let word = 0x20B00000 | group << 24 | channel << 16 | UInt32(action.rawValue) << 8
                    XCTAssertEqual(JamMIDIAction.decode([word | 127, word, word | 1]), [action, action])
                }
            }
        }
    }
    func testOtherMessagesAndMalformedValuesNeverTriggerOrLeakPayloadWords() {
        XCTAssertEqual(JamMIDIAction.decode([UInt32(0x2090167F), 0x20B0157F, 0x20B01B7F, 0x20B01680]), [])
        // SysEx and MIDI 2.0 payloads can look like MIDI 1 CCs; skip the whole UMP.
        XCTAssertEqual(JamMIDIAction.decode([UInt32(0x30000000), 0x20B0167F, 0x40000000, 0x20B0177F,
                                           0x50000000, 0x20B0187F, 0x20B0197F, 0x20B01A7F, 0x20B01A7F]), [.drummer])
        XCTAssertEqual(JamMIDIAction.decode([UInt32(0x50000000), 0x20B0167F]), [])
    }
    func testPacketSlicesAndLongBatchesPreserveEventOrder() {
        let words: [UInt32] = [0x10F80000] + (22...26).flatMap { [0x20B0007F | UInt32($0) << 8, 0x20B00000 | UInt32($0) << 8] }
        XCTAssertEqual(JamMIDIAction.decode(words.dropFirst()), JamMIDIAction.allCases)
        XCTAssertEqual(JamMIDIAction.decode(Array(repeating: UInt32(0x20B0167F), count: 200)).count, 200)
    }
}
