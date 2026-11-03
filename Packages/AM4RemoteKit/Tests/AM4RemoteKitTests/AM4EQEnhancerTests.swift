import XCTest
@testable import AM4RemoteKit

final class AM4EQEnhancerTests: XCTestCase {
    private func state(_ block: Int, model: Int, page: String? = nil) -> AM4EffectControls {
        let effect = AM4EffectsCatalog.shared.effect(block)!
        let context = AM4EffectContext(location: 92, scene: 1, blocks: [50,58,122,66], slot: block == 50 ? 0 : 2, block: block, channel: 2)
        let values = Dictionary(uniqueKeysWithValues: effect.parameters.map { definition in
            (definition.key, AM4ParameterValue(raw: definition.key == effect.typeKey ? UInt32(model) : 0,
                normalized: 0, text: definition.key == effect.typeKey ? effect.models[model] : "0"))
        })
        return AM4EffectControls(context: context, model: model, modelName: effect.models[model], page: page ?? effect.pages[0].id, values: values)
    }
    private func bands(_ model: Int, page: String = "Graphic EQ") -> [AM4AmpControl] {
        let state = state(50, model: model, page: page), effect = AM4EffectsCatalog.shared.effect(50)!
        return effect.controls(page: page, values: state.values).filter { (10...19).contains(effect.definition($0.key)!.parameter) }
    }
    func testGraphicEQTypesHaveCorrectBandCountsAndFrequencyLabels() {
        XCTAssertEqual(AM4EffectsCatalog.shared.effect(50)?.models.count, 18)
        let counts = [10,8,7,5,10,8,7,5,5,4,3,3,10,10,5,4,7,7]
        for model in counts.indices {
            XCTAssertEqual(bands(model).count, counts[model], "model \(model)")
            XCTAssertEqual(bands(model, page: "Expert").map(\.label), bands(model).map(\.label), "Expert layout, model \(model)")
        }
        XCTAssertEqual(bands(0).map(\.label), ["31","63","125","250","500","1k","2k","4k","8k","16k"])
        XCTAssertEqual(bands(14).map(\.label), ["80","240","750","2200","6600"])
        XCTAssertEqual(bands(15).map(\.label), ["Bass","Mid","Treble","Presence"])
        XCTAssertEqual(bands(17).map(\.label), ["62","125","250","500","1K","2K","4K"])
        XCTAssertFalse(bands(14).contains { $0.key == "50:15" })
    }
    func testEnhancerModesExposeOnlyTheirOwnControlsOnBothPages() {
        let effect = AM4EffectsCatalog.shared.effect(122)!
        XCTAssertEqual(effect.models, ["Modern","Classic","Stereoizer"])
        for page in effect.pages {
            let keys = (0..<3).map { model -> Set<String> in
                let source = state(122, model: model, page: page.id)
                return Set(effect.controls(page: page.id, values: source.values).map(\.key))
            }
            XCTAssertTrue(keys[0].isSuperset(of: ["122:10","122:11","122:12","122:13"]))
            XCTAssertTrue(keys[0].isDisjoint(with: ["122:15","122:16","122:17"]))
            XCTAssertTrue(keys[1].isSuperset(of: ["122:10","122:15","122:16","122:17"]))
            XCTAssertTrue(keys[1].isDisjoint(with: ["122:11","122:12","122:13"]))
            XCTAssertTrue(keys[2].isSuperset(of: ["122:10","122:11"]))
            XCTAssertTrue(keys[2].isDisjoint(with: ["122:12","122:13","122:15","122:16","122:17"]))
        }
    }
    func testTypeAddressesDoNotOverwriteFirstBandOrWidth() {
        for (block,parameter,model) in [(50,20,14),(122,14,1)] {
            let effect = AM4EffectsCatalog.shared.effect(block)!
            XCTAssertEqual(effect.typeParameter, parameter)
            let source = state(block, model: model)
            XCTAssertTrue(source.isValid)
            let message = AM4Message(bytes: AM4Message.effectValueWrite(block: block, parameter: effect.typeParameter, value: Float(model)))!
            XCTAssertEqual(Array(message.payload.prefix(6)), [UInt8(block),0,UInt8(parameter),0,1,0])
            let edit = AM4EffectEdit(state: source, key: "\(block):10", expected: source.values["\(block):10"]!, normalized: 0.5)
            XCTAssertTrue(edit.isValid)
            XCTAssertEqual(Array(AM4Message(bytes: edit.frame!)!.payload.prefix(6)), [UInt8(block),0,10,0,2,0])
            let reset = AM4EffectEdit(state: source, key: edit.key, expected: edit.expected, resetToDefault: true)
            XCTAssertEqual(AM4Message(bytes: reset.frame!)!.payload[4], 8)
        }
    }
    func testHiddenEnhancerAndEQControlsRejectStaleEdits() {
        let modern = state(122, model: 0), classic = state(122, model: 1)
        XCTAssertTrue(AM4EffectEdit(state: modern, key: "122:12", expected: modern.values["122:12"]!, normalized: 0.5).isValid)
        XCTAssertFalse(AM4EffectEdit(state: classic, key: "122:12", expected: classic.values["122:12"]!, normalized: 0.5).isValid)
        let mark = state(50, model: 14)
        XCTAssertFalse(AM4EffectEdit(state: mark, key: "50:19", expected: mark.values["50:19"]!, normalized: 0.5).isValid)
        XCTAssertFalse(AM4EffectSelection(state: modern, model: 3).isValid)
        XCTAssertFalse(AM4EffectSelection(state: mark, model: 18).isValid)
    }
    func testGraphicEQLibrariesReadTypeAtTwentyAndPreserveOtherChannels() {
        let entries = AM4EffectsLibrary.shared.entries.filter { $0.block == 50 }
        XCTAssertEqual(Set(entries.map(\.name)), Set(["Mark IV GEQ","Pre-Boost","HM-2 EQ","GE-7 Pre-Boost"]))
        for entry in entries {
            let file = entry.parsed!
            XCTAssertEqual(file.bank.stride, 23)
            XCTAssertFalse(file.allChannels)
            let model = file.bank.words[file.sourceChannel * file.bank.stride + 20]
            XCTAssertLessThan(model, 18)
            let original = AM4EffectBank(block: 50, words: [UInt32](repeating: 32767, count: 92))
            let merged = original.mergingEffectLibrary(file, channel: 2)!
            XCTAssertEqual(Array(merged.words[46..<69]), Array(file.bank.words[(file.sourceChannel*23)..<(file.sourceChannel*23+23)]))
            for channel in [0,1,3] { XCTAssertEqual(Array(merged.words[channel*23..<channel*23+23]), [UInt32](repeating: 32767,count:23)) }
            XCTAssertTrue(AM4EffectSelection(state: state(50,model:0),libraryID:entry.id).isValid)
            XCTAssertFalse(AM4EffectSelection(state: state(122,model:0),libraryID:entry.id).isValid)
        }
    }
    func testBankVerificationChecksActualTypeParameterAndVisibleValues() {
        for (block,stride,parameter) in [(50,23,20),(122,18,14)] {
            var words = [UInt32](repeating: 32767, count: stride*4)
            for channel in 0..<4 { words[channel*stride+parameter] = 0 }
            let bank = AM4EffectBank(block: block, words: words)
            XCTAssertTrue(bank.matchesEffect(bank,channel:2,allChannels:false))
            var changed = words; changed[2*stride+parameter] = 1
            XCTAssertFalse(bank.matchesEffect(AM4EffectBank(block:block,words:changed),channel:2,allChannels:false))
            changed = words; changed[2*stride+10] += 1000
            XCTAssertFalse(bank.matchesEffect(AM4EffectBank(block:block,words:changed),channel:2,allChannels:false))
            changed = words; changed[10] += 1000
            XCTAssertFalse(bank.matchesEffect(AM4EffectBank(block:block,words:changed),channel:2,allChannels:false))
            XCTAssertNotNil(AM4Message.libraryTransferMode(block:block))
        }
    }
}
