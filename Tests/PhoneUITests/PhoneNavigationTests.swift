import XCTest

final class PhoneNavigationTests: XCTestCase {
    @MainActor func testTabletSavedLoopBrowserInBothOrientations() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        continueAfterFailure = false
        let device = XCUIDevice.shared
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            device.orientation = orientation
            let open = app.buttons["Open saved loop"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
            XCTAssertTrue(app.textFields["Search loops"].isHittable)
            XCTAssertTrue(app.buttons["Open a loop file…"].isHittable)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.12)).tap()
        }
    }

    @MainActor func testPhoneWorkspacesInPortraitAndLandscape() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        let tabs = app.tabBars
        for title in ["Songs", "Chart", "Jam", "Tools", "AM4"] {
            XCTAssertTrue(tabs.buttons[title].waitForExistence(timeout: 5))
            tabs.buttons[title].tap()
        }
        XCTAssertTrue(app.buttons["Presets"].exists)
        app.buttons["Controls"].tap()
        tabs.buttons["Jam"].tap()
        XCTAssertTrue(app.buttons["Mix"].isHittable)
        app.buttons["Open saved loop"].tap()
        XCTAssertTrue(app.textFields["Search loops"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "iPhone Jam"
        image.lifetime = .keepAlways
        add(image)
        device.orientation = .landscapeLeft
        tabs.buttons["Tools"].tap()
        app.buttons["Chord Library"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Triads"].waitForExistence(timeout: 5))
    }
}
