import XCTest

final class PhoneNavigationTests: XCTestCase {
    @MainActor func testTabletJamAndSavedLoopBrowserInBothOrientations() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        continueAfterFailure = false
        let device = XCUIDevice.shared
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            device.orientation = orientation
            let jam = app.buttons["Show or hide jam"]
            XCTAssertTrue(jam.waitForExistence(timeout: 5))
            if jam.value as? String == "Hidden" { jam.tap() }
            let open = app.buttons["Open saved loop"]
            let player = app.buttons["Browse audio files"]
            let drums = app.buttons["Play drums"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            jam.tap()
            XCTAssertTrue(open.waitForNonExistence(timeout: 5))
            XCTAssertFalse(player.exists)
            XCTAssertFalse(drums.exists)
            jam.tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            for label in ["AM4", "Chords", "Scales"] {
                XCTAssertTrue(app.buttons[label].exists)
            }
            open.tap()
            XCTAssertTrue(app.textFields["Search loops"].isHittable)
            XCTAssertTrue(app.buttons["Open a loop file…"].isHittable)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.12)).tap()
        }
    }

    @MainActor func testSelectingAndEditingSongOnPhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--phone-test-library",
            #"{"songs":[{"id":"fixture-song","title":"Phone Test Song","rawData":"{title: Phone Test Song}\n{key: C}\nAlignment check\n[C]One chord"}],"playlists":[{"id":"fixture-playlist","title":"Practice","arrangement":[{"type":"song","id":"fixture-song"}]}]}"#]
        app.launch()
        let songRow = app.staticTexts["Phone Test Song"]
        XCTAssertTrue(songRow.waitForExistence(timeout: 10))
        let playlist = app.buttons["Playlist"]
        XCTAssertTrue(playlist.isHittable)
        playlist.tap()
        app.buttons["Practice"].tap()
        XCTAssertEqual(playlist.value as? String, "Practice")
        songRow.tap()
        let edit = app.buttons["Edit song"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Smaller chart text"].isHittable)
        XCTAssertTrue(app.buttons["Larger chart text"].isHittable)
        let title = app.staticTexts["Phone Test Song"]
        let lyric = app.staticTexts["Alignment check"]
        XCTAssertTrue(lyric.exists)
        XCTAssertEqual(title.frame.minX, lyric.frame.minX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(lyric.frame.minY - edit.frame.maxY, 18)
        let chart = XCTAttachment(screenshot: app.screenshot())
        chart.name = "iPhone Chart"
        chart.lifetime = .keepAlways
        add(chart)
        edit.tap()
        XCTAssertTrue(app.buttons["Song details"].waitForExistence(timeout: 5))
        app.buttons["Song details"].tap()
        let capo = app.buttons["song-capo-picker"]
        XCTAssertTrue(capo.waitForExistence(timeout: 5))
        capo.tap()
        app.buttons["3"].tap()
        let name = app.textFields["Song name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" Edited")
        app.buttons["Done"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Phone Test Song Edited"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Capo 3")).firstMatch.exists)
    }

    @MainActor func testMobileSettings() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.tabBars.buttons["Tools"].tap()
        }
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Input"].exists)
        XCTAssertTrue(app.staticTexts["Capture Channels"].exists)
        XCTAssertTrue(app.staticTexts["Output"].exists)
        XCTAssertTrue(app.buttons["Choose library folder…"].isHittable)
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "Settings"
        settings.lifetime = .keepAlways
        add(settings)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
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
        for title in ["Songs", "Chart", "Jam", "Tools"] {
            XCTAssertTrue(tabs.buttons[title].waitForExistence(timeout: 5))
            tabs.buttons[title].tap()
        }
        XCTAssertFalse(tabs.buttons["AM4"].exists)
        app.buttons["AM4"].tap()
        XCTAssertTrue(app.buttons["Presets"].waitForExistence(timeout: 5))
        app.buttons["Controls"].tap()
        app.buttons["Close AM4 Remote"].tap()
        XCTAssertTrue(app.buttons["Chords"].isHittable)
        tabs.buttons["Jam"].tap()
        XCTAssertTrue(app.buttons["Mix"].isHittable)
        let player = app.buttons["Browse audio files"]
        let drums = app.buttons["Play drums"]
        let looper = app.buttons["Open saved loop"]
        XCTAssertTrue(player.isHittable)
        XCTAssertLessThan(player.frame.midY, drums.frame.midY)
        XCTAssertLessThan(drums.frame.midY, looper.frame.midY)
        if !looper.isHittable { app.swipeUp() }
        looper.tap()
        XCTAssertTrue(app.textFields["Search loops"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "iPhone Jam"
        image.lifetime = .keepAlways
        add(image)
        device.orientation = .landscapeLeft
        tabs.buttons["Tools"].tap()
        app.buttons["Chords"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Triads"].waitForExistence(timeout: 5))
    }
}
