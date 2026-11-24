import XCTest
@testable import MacLooper

final class AudioFolderPersistenceTests: XCTestCase {
    @MainActor func testLastFolderReopensAndRescansWithoutAutoplay() async throws {
        let suite = "MacLooperFolderTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Set"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appendingPathComponent("Set/Test.mp3"))
        let first = AudioFilePlayerModel(defaults: defaults, restoreFolder: false)
        first.openFolder(folder)
        for _ in 0..<200 where first.scanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(first.trackCount, 1)
        XCTAssertEqual(first.tracks.map(\.fileName), ["Test.mp3"])
        first.query = "missing"
        XCTAssertTrue(first.visibleGroups.isEmpty)
        XCTAssertEqual(first.tracks.count, 1, "Search must not change transport order")
        XCTAssertNotNil(defaults.data(forKey: "audioPlayerFolder"))
        first.shutdown()
        let reopened = AudioFilePlayerModel(defaults: defaults)
        defer { reopened.shutdown() }
        for _ in 0..<200 where reopened.scanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reopened.folder?.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        XCTAssertEqual(reopened.trackCount, 1)
        XCTAssertNil(reopened.selected); XCTAssertFalse(reopened.playing)
        let empty = folder.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        reopened.openFolder(empty)
        XCTAssertTrue(reopened.tracks.isEmpty, "Discard the previous folder’s cached tracks immediately")
        for _ in 0..<200 where reopened.scanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(reopened.groups.isEmpty)
        XCTAssertEqual(reopened.trackCount, 0)
    }
}
