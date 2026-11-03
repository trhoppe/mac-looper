import XCTest
@testable import AM4RemoteKit

final class AM4AmpLibraryTests: XCTestCase {
    private let context = AM4AmpContext(location: 92, scene: 0, blocks: [0x3A, 0x76, 0x46, 0x42], channel: 0)

    func testPersonalLibraryParsesEveryOriginalFile() {
        let library = AM4AmpLibrary.shared
        XCTAssertEqual(library.entries.count, 45)
        XCTAssertEqual(Set(library.entries.map(\.id)).count, 45)
        for entry in library.entries {
            let block = entry.blockFile
            XCTAssertNotNil(block, entry.name)
            XCTAssertEqual(block?.dumps.count, 2, entry.name)
            XCTAssertEqual(block?.dumps.first?.first?.payload.first, 0x3A)
            XCTAssertEqual(block?.dumps.last?.first?.payload.first, 0x3E)
        }
    }

    func testRejectsWrongDeviceScopeTruncationAndDamagedChecksum() {
        let original = AM4AmpLibrary.shared.entries[0].file
        for (offset, value) in [(0, 4), (2, 0x14), (22, 0x76), (26, 0), (30, 4), (34, 255)] {
            var bytes = original; bytes[offset] = UInt8(value)
            XCTAssertNil(AM4AmpBlockFile(data: bytes))
        }
        XCTAssertNil(AM4AmpBlockFile(data: original.prefix(60)))
        var damaged = original
        let header = damaged.range(of: Data([0xF0, 0, 1, 0x74, 0x15, 0x74]))!.lowerBound
        damaged[header + 8] ^= 1
        XCTAssertNil(AM4AmpBlockFile(data: damaged))
    }

    func testTypeWriteCarriesAnAbsoluteModelIndex() {
        let command = AM4AmpSelection(context: context, expectedModel: 0, model: 181)
        let message = AM4Message(bytes: AM4Message.ampModelWrite(command)!)!
        XCTAssertEqual(message.function, 1)
        XCTAssertEqual(Array(message.payload.prefix(10)), [58, 0, 10, 0, 1, 0, 0, 0, 4, 0])
        XCTAssertEqual(AM4Message.unpack(Array(message.payload.dropFirst(10)), count: 4), [0, 0, 53, 67])
        XCTAssertNil(AM4Message.ampModelWrite(AM4AmpSelection(context: context, expectedModel: 0,
                                                            libraryID: AM4AmpLibrary.shared.entries[0].id)))
    }

    func testSelectionRequiresOneValidTargetAndFreshModelIdentity() {
        XCTAssertTrue(AM4AmpSelection(context: context, expectedModel: 0, model: 250).isValid)
        XCTAssertTrue(AM4AmpSelection(context: context, expectedModel: 250,
                                      libraryID: AM4AmpLibrary.shared.entries[0].id).isValid)
        XCTAssertFalse(AM4AmpSelection(context: context, expectedModel: 251, model: 0).isValid)
        XCTAssertFalse(AM4AmpSelection(context: context, expectedModel: 0, model: -1).isValid)
        XCTAssertFalse(AM4AmpSelection(context: context, expectedModel: 0, model: 251).isValid)
        XCTAssertFalse(AM4AmpSelection(context: context, expectedModel: 0).isValid)
        XCTAssertFalse(AM4AmpSelection(context: context, expectedModel: 0, libraryID: "../unknown").isValid)
        XCTAssertFalse(AM4AmpSelection(context: context, expectedModel: 0, model: 1,
                                       libraryID: AM4AmpLibrary.shared.entries[0].id).isValid)
    }

    func testChannelsDecodeTheirTypedFieldAndRejectTransitionGarbage() {
        for channel in 0..<4 {
            // The first word can contain undefined padding; do not interpret it.
            var raw: [UInt8] = [0xEC, 0x2B, 0x80, 0x3F, UInt8(channel), 0, 0, 0, UInt8(65 + channel), 0]
            raw += [UInt8](repeating: 0, count: 30)
            func reply(_ bytes: [UInt8]) -> AM4Message {
                AM4Message(bytes: AM4Message.request(function: 1,
                    payload: [58, 0, 82, 15, 13, 0, 0, 0, 40, 0] + AM4Message.pack(bytes)))!
            }
            XCTAssertEqual(reply(raw).ampChannel, channel)
            raw[8] = 0
            XCTAssertNil(reply(raw).ampChannel)
            raw[8] = UInt8(65 + channel); raw[7] = 128
            XCTAssertNil(reply(raw).ampChannel)
        }
        XCTAssertNil(AM4Message.ampChannelWrite(-1))
        XCTAssertNil(AM4Message.ampChannelWrite(4))
        XCTAssertTrue(AM4AmpSelection(context: context, expectedModel: 0, channel: 3).isValid)
    }

    func testLibraryMergesMatchRealDesktopCapturesInChannelsAAndB() throws {
        struct Capture: Decodable {
            let name: String; let channel: Int; let blocks: [BankCapture]
        }
        struct BankCapture: Decodable {
            let block: Int; let before: [Data]; let after: [Data]
        }
        let url = Bundle.module.url(forResource: "AmpLibraryCapture", withExtension: "json")!
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: url))
        func bank(_ frames: [Data], block: Int) -> AM4EffectBank? {
            var reader = AM4EffectBankReader(block: block)
            for frame in frames { reader.receive(AM4Message(bytes: [UInt8](frame))!) }
            XCTAssertTrue(reader.completed)
            return reader.bank
        }
        for capture in captures {
            let file = AM4AmpLibrary.shared.entries.first { $0.name == capture.name }!.blockFile!
            for item in capture.blocks {
                let original = bank(item.before, block: item.block)!
                let source = file.banks.first { $0.block == item.block }!
                let merged = original.merging(source, from: file.sourceChannel, into: capture.channel)!
                XCTAssertEqual(merged, bank(item.after, block: item.block), capture.name)
                XCTAssertEqual(merged.frames.map(Data.init), item.after, capture.name)
                for channel in 0..<4 where channel != capture.channel {
                    let range = channel * original.stride..<(channel + 1) * original.stride
                    XCTAssertEqual(Array(merged.words[range]), Array(original.words[range]))
                }
                XCTAssertTrue(merged.frames.allSatisfy { $0.count <= 778 })
            }
        }
    }

    func testRejectsIncompleteBanksAndWrongBlockMerges() {
        let file = AM4AmpLibrary.shared.entries[0].blockFile!
        let source = file.banks[0]
        var reader = AM4EffectBankReader(block: source.block)
        for frame in source.frames.dropLast(2) { reader.receive(AM4Message(bytes: frame)!) }
        reader.receive(AM4Message(bytes: AM4Message.request(function: 0x76))!)
        XCTAssertNil(reader.bank)
        XCTAssertNil(source.merging(file.banks[1], from: 0, into: 1))
        XCTAssertNil(source.merging(source, from: 4, into: 1))
    }

    func testNativeDesktopPostLoadNormalizationDoesNotHideSavedControlChanges() throws {
        struct BankCapture: Decodable { let block: Int; let before: [Data]; let after: [Data] }
        struct Capture: Decodable { let name: String; let channel: Int; let blocks: [BankCapture] }
        let data = try Data(contentsOf: Bundle.module.url(forResource: "AmpLibraryCapture", withExtension: "json")!)
        let captures = try JSONDecoder().decode([Capture].self, from: data)
        func bank(_ frames: [Data], _ block: Int) -> AM4EffectBank {
            var reader = AM4EffectBankReader(block: block)
            frames.forEach { reader.receive(AM4Message(bytes: [UInt8]($0))!) }
            return reader.bank!
        }
        let sentSRV = bank(captures[0].blocks[0].after, 58)
        let laterSRV = bank(captures[1].blocks[0].before, 58)
        XCTAssertNotEqual(sentSRV, laterSRV)
        XCTAssertEqual(sentSRV.words[45], 15859)
        XCTAssertEqual(laterSRV.words[45], 15794)
        XCTAssertTrue(sentSRV.matchesLoaded(laterSRV, channel: 0))
        XCTAssertFalse(sentSRV.matchesLoaded(laterSRV, channel: 1))
        for parameter in [10, 11, 12, 14] {
            var changed = laterSRV.words; changed[parameter] += 1
            XCTAssertFalse(sentSRV.matchesLoaded(AM4EffectBank(block: 58, words: changed), channel: 0))
        }
        var changedOtherChannel = laterSRV.words; changedOtherChannel[sentSRV.stride + 45] += 1
        XCTAssertFalse(sentSRV.matchesLoaded(AM4EffectBank(block: 58, words: changedOtherChannel), channel: 0))
        let sentCab = bank(captures[1].blocks[1].after, 62)
        let laterCab = bank(captures[2].blocks[1].before, 62)
        // Native AC30 has mic 2 muted; its blend is inactive, and the desktop
        // also retains the previous runtime pair after loading that preset.
        XCTAssertEqual(sentCab.words[23], 1)
        XCTAssertTrue(sentCab.matchesLoaded(laterCab, channel: 0))
        // With both mics on, a large blend difference must be restored.
        var bothOn = sentCab.words; bothOn[23] = 0
        var wrongBlend = laterCab.words; wrongBlend[23] = 0
        XCTAssertFalse(AM4EffectBank(block: 62, words: bothOn).matchesLoaded(AM4EffectBank(block: 62, words: wrongBlend), channel: 0))
        var roundedCab = sentCab.words; roundedCab[75] -= 1; roundedCab[76] += 1
        XCTAssertTrue(sentCab.matchesLoaded(AM4EffectBank(block: 62, words: roundedCab), channel: 0))
    }

    func testAutomaticSpeakerModeVerifiesCurveAndModeRatherThanDerivedCoefficients() {
        let source = AM4AmpLibrary.shared.entries.first { $0.name == "SRV" }!.blockFile!.banks[0]
        let stride = source.stride
        var words = Array(source.words[0..<stride])
        words[146] = 1
        let original = AM4EffectBank(block: 58, words: words + words + words + words)
        var changed = original.words
        for index in [33, 34, 48, 50, 51, 107] { changed[index] = 32767 }
        XCTAssertTrue(original.matchesLoaded(AM4EffectBank(block: 58, words: changed), channel: 0))
        changed[135] += 1
        XCTAssertFalse(original.matchesLoaded(AM4EffectBank(block: 58, words: changed), channel: 0))
        changed[135] -= 1; changed[stride + 33] += 1
        XCTAssertFalse(original.matchesLoaded(AM4EffectBank(block: 58, words: changed), channel: 0))
        changed[stride + 33] -= 1
        var manual = original.words; manual[146] = 0; changed[146] = 0
        XCTAssertFalse(AM4EffectBank(block: 58, words: manual).matchesLoaded(AM4EffectBank(block: 58, words: changed), channel: 0))
    }
}
