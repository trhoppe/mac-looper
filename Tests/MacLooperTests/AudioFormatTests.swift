import XCTest
@testable import MacLooper
final class AudioFormatTests: XCTestCase {
    @MainActor func testDiscreteAM4AndAggregateFormatsSupportMoreThanStereo() throws {
        for channels: UInt32 in [1,2,4,6,8] {
            let format = try AudioEngineHost.captureFormat(rate: 48000, channels: channels)
            XCTAssertEqual(format.channelCount, channels)
            XCTAssertEqual(format.sampleRate, 48000)
            XCTAssertFalse(format.isInterleaved)
        }
        XCTAssertThrowsError(try AudioEngineHost.captureFormat(rate: 0, channels: 4))
        XCTAssertThrowsError(try AudioEngineHost.captureFormat(rate: 48000, channels: 0))
    }
}
