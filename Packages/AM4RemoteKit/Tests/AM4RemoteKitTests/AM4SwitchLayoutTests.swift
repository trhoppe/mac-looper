import XCTest
@testable import AM4RemoteKit

final class AM4SwitchLayoutTests: XCTestCase {
    private let catalog = AM4AmpCatalog.shared
    private func values(model: Int) -> [String: AM4ParameterValue] {
        Dictionary(uniqueKeysWithValues: catalog.parameters.map {
            ($0.key, AM4ParameterValue(raw: $0.key == "58:10" ? UInt32(model) : 0,
                                      normalized: 0, text: "OFF"))
        })
    }
    func testBypassAndOnOffUseSwitchesWhileCategoricalMenusRemainMenus() {
        let state = values(model: 207)
        let controls = catalog.pages.flatMap(\.controls)
        let bypass = controls.first { $0.key == "58:3" }!
        let preamp = controls.first { $0.key == "58:141" }!
        let cabinetMode = controls.first { $0.key == "62:24" }!
        XCTAssertTrue(catalog.usesSwitch(bypass, values: state))
        XCTAssertTrue(catalog.usesSwitch(preamp, values: state))
        XCTAssertFalse(catalog.usesSwitch(cabinetMode, values: state))
    }
    func testSameDynamicParameterUsesCorrectWidgetForDifferentAmps() {
        // FT37's Mid/Gain Boost is a toggle; ODS Ford's Switches is a menu.
        let ft37 = values(model: 62), ods = values(model: 110)
        let toggle = catalog.controls(page: "Amp", values: ft37).first { $0.key == "58:148" }!
        let menu = catalog.controls(page: "Amp", values: ods).first { $0.key == "58:148" }!
        XCTAssertTrue(catalog.usesSwitch(toggle, values: ft37))
        XCTAssertFalse(catalog.usesSwitch(menu, values: ods))
        let expert = catalog.controls(page: "Expert", values: ft37).first { $0.key == "58:148" }!
        XCTAssertTrue(catalog.usesSwitch(expert, values: ft37))
    }
}
