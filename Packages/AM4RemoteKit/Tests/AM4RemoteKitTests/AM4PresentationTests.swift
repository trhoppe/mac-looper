import XCTest
@testable import AM4RemoteKit

final class AM4PresentationTests: XCTestCase {
    @MainActor func testClosePausesPollingWithoutDroppingCurrentConnectionObject() {
        let session = AM4RemoteSession(connectAutomatically: false)
        let connection = session.connection
        XCTAssertFalse(session.isPresented)
        session.present()
        XCTAssertTrue(session.isPresented)
        XCTAssertTrue(connection.pollingEnabled)
        session.dismiss()
        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(connection.pollingEnabled)
        XCTAssertTrue(session.connection === connection)
        session.present()
        XCTAssertTrue(session.isPresented)
        XCTAssertTrue(connection.pollingEnabled)
        XCTAssertTrue(session.connection === connection)
        session.stop()
    }
}

extension AM4PresentationTests {
    @MainActor func testCloseClearsAmpSubscriptionAndReopensOnMainPage() async throws {
        let session = AM4RemoteSession(connectAutomatically: false)
        session.present()
        let page = try XCTUnwrap(AM4AmpCatalog.shared.pages.first?.id)
        await session.connection.showAmpPage(page)
        XCTAssertEqual(session.connection.ampPage, page)
        session.dismiss()
        XCTAssertNil(session.connection.ampPage)
        XCTAssertNil(session.connection.effectPage)
        session.present()
        XCTAssertNil(session.connection.ampPage)
        XCTAssertNil(session.connection.effectPage)
        session.stop()
    }
}

extension AM4PresentationTests {
    @MainActor func testBackgroundPausesPollingWithoutClosingRemote() {
        let session = AM4RemoteSession(connectAutomatically: false)
        session.present()
        session.setApplicationActive(false)
        XCTAssertTrue(session.isPresented)
        XCTAssertFalse(session.connection.pollingEnabled)
        session.setApplicationActive(true)
        XCTAssertTrue(session.isPresented)
        XCTAssertTrue(session.connection.pollingEnabled)
        session.dismiss(); session.setApplicationActive(true)
        XCTAssertFalse(session.connection.pollingEnabled)
        session.stop()
    }
}
