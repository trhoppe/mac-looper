import XCTest
import JamCore

final class AudioLifecycleTests: XCTestCase {
    func testBackgroundAndInterruptionsNeverReconnectUntilBothHaveEnded() {
        var policy = AudioLifecyclePolicy()
        XCTAssertEqual(policy.handle(.interruptionBegan), .suspend)
        XCTAssertEqual(policy.handle(.background), .suspend)
        XCTAssertEqual(policy.handle(.interruptionEnded(mayReconnect: true)), .none)
        XCTAssertFalse(policy.mayConnect)
        XCTAssertEqual(policy.handle(.foreground), .reconnect)
        XCTAssertTrue(policy.mayConnect)
    }
    func testDeniedResumeAndMediaResetRequireExplicitRetry() {
        var policy = AudioLifecyclePolicy()
        _ = policy.handle(.interruptionBegan)
        XCTAssertEqual(policy.handle(.interruptionEnded(mayReconnect: false)), .none)
        XCTAssertEqual(policy.handle(.foreground), .none)
        XCTAssertEqual(policy.handle(.retry), .reconnect)
        XCTAssertEqual(policy.handle(.mediaServicesReset), .reset)
        XCTAssertFalse(policy.mayConnect)
        XCTAssertEqual(policy.handle(.background), .suspend)
        XCTAssertEqual(policy.handle(.retry), .none)
        XCTAssertEqual(policy.handle(.foreground), .none)
        XCTAssertEqual(policy.handle(.retry), .reconnect)
    }
}
