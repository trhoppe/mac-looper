import XCTest
@testable import JamCore

final class SavedLoopTests: XCTestCase {
    func testLosslessStereoRoundTripPreservesEarlyFinishAndMetadata() throws {
        let left = (0..<1501).map { Float($0) / 1501 - 0.5 }, right = left.map { -$0 / 2 }
        let take = try SavedLoop(sampleRate: 44100, bpm: 137, bars: 4, left: left, right: right)
        let data = try take.encoded(), recalled = try SavedLoop.decode(data)
        XCTAssertEqual(recalled.sampleRate, 44100); XCTAssertEqual(recalled.bpm, 137); XCTAssertEqual(recalled.bars, 4)
        XCTAssertEqual(recalled.frames, 1501); XCTAssertEqual(recalled.channels().left, left); XCTAssertEqual(recalled.channels().right, right)
        XCTAssertLessThan(data.count, left.count * 8 + 1000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jamloop")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        XCTAssertEqual(try SavedLoop.decode(Data(contentsOf: url)).leftPCM, take.leftPCM)
    }
    func testMalformedUnsupportedAndUnsafeAudioAreRejected() throws {
        let valid = try SavedLoop(sampleRate: 48000, bpm: 120, bars: 4, left: Array(repeating: 0.5, count: 32), right: Array(repeating: -0.2, count: 32))
        let data = try valid.encoded()
        XCTAssertThrowsError(try SavedLoop.decode(Data("not a loop".utf8)))
        XCTAssertThrowsError(try SavedLoop.decode(data.prefix(data.count / 2)))
        let fields: [(String, Any)] = [("version", 99), ("sampleRate", 0), ("bpm", 500), ("bars", 0), ("rightPCM", Data(count: 4)), ("leftPCM", Data(count: 3))]
        for (key, value) in fields {
            var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            plist[key] = value
            let bad = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            XCTAssertThrowsError(try SavedLoop.decode(bad), key)
        }
        XCTAssertThrowsError(try SavedLoop(sampleRate: .nan, bpm: 120, bars: 4, left: [], right: []))
        XCTAssertThrowsError(try SavedLoop(sampleRate: 48000, bpm: 120, bars: 4, left: Array(repeating: .nan, count: 32), right: Array(repeating: 0, count: 32)))
    }
}
