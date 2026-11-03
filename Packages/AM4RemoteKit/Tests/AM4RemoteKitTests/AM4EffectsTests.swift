import XCTest
@testable import AM4RemoteKit

final class AM4EffectsTests: XCTestCase {
    private let blocks: [UInt32] = [118, 58, 70, 66]
    private func context(_ block: Int = 118, channel: Int = 0) -> AM4EffectContext {
        let layout: [UInt32] = [50,122].contains(block) ? [50,58,122,66] : blocks
        return AM4EffectContext(location: 92, scene: 0, blocks: layout, slot: layout.firstIndex(of: UInt32(block))!, block: block, channel: channel)
    }
    private func state(_ block: Int = 118, model: Int = 0, page: String? = nil) -> AM4EffectControls {
        let effect = AM4EffectsCatalog.shared.effect(block)!
        let values = Dictionary(uniqueKeysWithValues: effect.parameters.map { definition in
            (definition.key, AM4ParameterValue(raw: definition.key == effect.typeKey ? UInt32(model) : 0, normalized: 0, text: definition.key == effect.typeKey ? effect.models[model] : "0"))
        })
        return AM4EffectControls(context: context(block), model: model, modelName: effect.models[model], page: page ?? effect.pages[0].id, values: values)
    }
    func testCatalogsContainEveryModelAndAllVisibilityDependencies() {
        let catalog = AM4EffectsCatalog.shared
        XCTAssertEqual(catalog.effect(118)?.models.count, 78)
        XCTAssertEqual(catalog.effect(70)?.models.count, 29)
        XCTAssertEqual(catalog.effect(66)?.models.count, 79)
        for effect in catalog.effects {
            for page in effect.pages {
                for control in page.controls {
                    XCTAssertNotNil(effect.definition(control.key), control.key)
                    for condition in control.conditions { XCTAssertNotNil(effect.definition(condition.key), condition.key) }
                    if let key = control.lockKey { XCTAssertNotNil(effect.definition(key)) }
                }
            }
            for model in effect.models.indices {
                let state = self.state(effect.block, model: model)
                XCTAssertTrue(state.isValid)
                XCTAssertFalse(effect.controls(page: effect.pages[0].id, values: state.values).isEmpty, "\(effect.name) \(model)")
            }
        }
    }
    func testEveryPersonalLibraryFileImportsWithCorrectDeviceAndScope() {
        let library = AM4EffectsLibrary.shared
        XCTAssertEqual(library.entries.filter { $0.block == 118 }.count, 41)
        XCTAssertEqual(library.entries.filter { $0.block == 70 }.count, 24)
        XCTAssertEqual(library.entries.filter { $0.block == 66 }.count, 16)
        XCTAssertEqual(Set(library.entries.map(\.id)).count, 85)
        XCTAssertEqual(library.entries.filter { $0.block == 50 }.count, 4)
        XCTAssertEqual(library.entries.filter { $0.block == 122 }.count, 0)
        for entry in library.entries {
            XCTAssertNotNil(entry.parsed, entry.name)
            XCTAssertEqual(entry.parsed?.bank.block, entry.block)
            XCTAssertTrue(entry.parsed!.bank.frames.allSatisfy { AM4Message(bytes: $0) != nil })
        }
        XCTAssertEqual(library.entries.filter { $0.parsed?.allChannels == true }.count, 1)
    }
    func testLegacyLibraryAddsOnlyTrailingParametersAndPreservesOtherChannels() {
        for entry in AM4EffectsLibrary.shared.entries {
            let file = entry.parsed!
            let currentStride = [118:50, 70:90, 66:73, 50:23][entry.block]!
            let original = AM4EffectBank(block: entry.block, words: [UInt32](repeating: 1234, count: currentStride * 4))
            let merged = original.mergingEffectLibrary(file, channel: 2)!
            for channel in 0..<4 {
                let loaded = file.allChannels || channel == 2
                for parameter in 0..<currentStride {
                    let actual = merged.words[channel * currentStride + parameter]
                    if loaded && parameter < file.bank.stride {
                        let sourceChannel = file.allChannels ? channel : file.sourceChannel
                        XCTAssertEqual(actual, file.bank.words[sourceChannel * file.bank.stride + parameter])
                    } else { XCTAssertEqual(actual, 1234) }
                }
            }
        }
    }
    func testLibraryRejectsWrongClassDeviceTruncationAndBadChecksum() {
        let entry = AM4EffectsLibrary.shared.entries.first { $0.block == 118 }!
        XCTAssertNil(AM4EffectLibraryFile(data: entry.file, block: 66))
        XCTAssertNil(AM4EffectLibraryFile(data: entry.file.prefix(60), block: 118))
        var data = entry.file; data[2] = 0x10
        XCTAssertNil(AM4EffectLibraryFile(data: data, block: 118))
        data = entry.file
        let start = data.range(of: Data([240, 0, 1, 116]))!.lowerBound
        data[start + 8] ^= 1
        XCTAssertNil(AM4EffectLibraryFile(data: data, block: 118))
    }
    func testContextAndSelectionsRejectStaleOrWrongBlockData() {
        let state = self.state()
        XCTAssertTrue(state.isValid)
        XCTAssertTrue(AM4EffectSelection(state: state, model: 77).isValid)
        XCTAssertTrue(AM4EffectSelection(state: state, channel: 3).isValid)
        XCTAssertFalse(AM4EffectSelection(state: state, model: 78).isValid)
        XCTAssertFalse(AM4EffectSelection(state: state, channel: 4).isValid)
        XCTAssertFalse(AM4EffectSelection(state: state).isValid)
        XCTAssertFalse(AM4EffectSelection(state: state, model: 1, channel: 1).isValid)
        let reverb = AM4EffectsLibrary.shared.entries.first { $0.block == 66 }!
        XCTAssertFalse(AM4EffectSelection(state: state, libraryID: reverb.id).isValid)
        XCTAssertFalse(AM4EffectContext(location: 92, scene: 0, blocks: blocks, slot: 2, block: 118, channel: 0).isValid)
        XCTAssertNotEqual(context(channel: 0), context(channel: 1))
    }
    func testTempoLockPreventsEditingTimeAndNumericEditsRequireOneOperation() {
        let effect = AM4EffectsCatalog.shared.effect(70)!
        var values = state(70).values
        let page = effect.pages[0]
        let control = effect.controls(page: page.id, values: values).first { $0.lockKey != nil }!
        let key = control.key, lock = control.lockKey!
        values[lock] = AM4ParameterValue(raw: 1, normalized: 0.1, text: "1/4")
        let locked = AM4EffectControls(context: context(70), model: 0, modelName: effect.models[0], page: page.id, values: values)
        XCTAssertTrue(effect.locked(control, values: values))
        XCTAssertFalse(AM4EffectEdit(state: locked, key: key, expected: values[key]!, normalized: 0.5).isValid)
        values[lock] = AM4ParameterValue(raw: 0, normalized: 0, text: "NONE")
        let unlocked = AM4EffectControls(context: context(70), model: 0, modelName: effect.models[0], page: page.id, values: values)
        XCTAssertTrue(AM4EffectEdit(state: unlocked, key: key, expected: values[key]!, normalized: 0.5).isValid)
        XCTAssertFalse(AM4EffectEdit(state: unlocked, key: key, expected: values[key]!, normalized: .nan).isValid)
        XCTAssertFalse(AM4EffectEdit(state: unlocked, key: key, expected: values[key]!, normalized: 0.5, direction: 1).isValid)
    }
    func testMessagesUseTheSelectedBlockAndChannel() {
        for block in [118,70,66] {
            let effect = AM4EffectsCatalog.shared.effect(block)!
            let source = state(block)
            let control = effect.controls(page: source.page, values: source.values).first { effect.definition($0.key)?.isDiscrete == false && !effect.locked($0, values: source.values) }!
            let edit = AM4EffectEdit(state: source, key: control.key, expected: source.values[control.key]!, normalized: 0.5)
            XCTAssertTrue(edit.isValid)
            let message = AM4Message(bytes: edit.frame!)!
            XCTAssertEqual(message.payload[0], UInt8(block)); XCTAssertEqual(message.payload[4], 2)
            let reset = AM4EffectEdit(state: source, key: control.key, expected: source.values[control.key]!, resetToDefault: true)
            XCTAssertEqual(AM4Message(bytes: reset.frame!)!.payload[4], 8)
            let type = AM4Message(bytes: AM4Message.effectValueWrite(block: block, parameter: 10, value: 3))!
            XCTAssertEqual(Array(type.payload.prefix(6)), [UInt8(block),0,10,0,1,0])
            for channel in 0..<4 {
                let raw: [UInt8] = [0,0,99,0,UInt8(channel),0,0,0,UInt8(65+channel)] + [UInt8](repeating: 0, count: 31)
                let reply = AM4Message(bytes: AM4Message.request(function: 1, payload: [UInt8(block),0,82,15,13,0,0,0,40,0] + AM4Message.pack(raw)))!
                XCTAssertEqual(reply.effectChannel(block), channel)
                XCTAssertNil(reply.effectChannel(block == 118 ? 70 : 118))
            }
        }
    }
    func testLibraryVerificationRejectsAlteredControlsAndInactiveChannels() {
        let entry = AM4EffectsLibrary.shared.entries.first { $0.block == 118 }!, bank = entry.parsed!.bank
        XCTAssertTrue(bank.matchesEffect(bank, channel: 0, allChannels: false))
        var changed = bank.words; changed[bank.stride + 11] ^= 1024
        XCTAssertFalse(bank.matchesEffect(AM4EffectBank(block: bank.block, words: changed), channel: 0, allChannels: false))
        for parameter in 0..<10 {
            var header = bank.words; header[parameter] ^= 1
            XCTAssertFalse(bank.matchesEffect(AM4EffectBank(block: bank.block, words: header), channel: 0, allChannels: false))
        }
        changed = bank.words; changed[10] = (changed[10] + 1) % 78
        XCTAssertFalse(bank.matchesEffect(AM4EffectBank(block: bank.block, words: changed), channel: 0, allChannels: true))
    }
}

extension AM4EffectsTests {
    func testCapturedDelayExpertBypassModeAcceptsAbsoluteOrdinalFloat() throws {
        // Exact payload read from the connected AM4 on 2026-11-02. Previously
        // rejected by the normalized-only range check, appearing as a timeout.
        let payload: [UInt8] = [70,0,4,0,13,0,0,0,40,0,1,64,0,0,0,0,0,64,32,19,46,87,35,20,64,70,44,8,9,22,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
        let definition = try XCTUnwrap(AM4EffectsCatalog.shared.effect(70)?.definition("70:4"))
        let message = try XCTUnwrap(AM4Message(bytes: AM4Message.request(function: 1, payload: payload)))
        XCTAssertTrue(message.isParameterResponse(definition))
        let value = try XCTUnwrap(message.parameterValue(definition))
        XCTAssertEqual(value.raw, 3); XCTAssertEqual(value.normalized, 3); XCTAssertEqual(value.text, "Mute FX In")
        XCTAssertEqual(definition.ordinal(value), 3)
        XCTAssertTrue(definition.accepts(AM4ParameterValue(raw: 3, normalized: 0.75, text: "Mute FX In")))
        XCTAssertFalse(definition.accepts(AM4ParameterValue(raw: 3, normalized: 4, text: "wrong ordinal")))
        XCTAssertFalse(definition.accepts(AM4ParameterValue(raw: 999, normalized: 999, text: "out of range")))
        let continuous = try XCTUnwrap(AM4EffectsCatalog.shared.effect(70)?.definition("70:1"))
        XCTAssertFalse(continuous.accepts(value), "Continuous parameters still require normalized values")
        XCTAssertFalse(message.isParameterResponse(continuous), "Other addresses must not satisfy the pending read")
    }
}
