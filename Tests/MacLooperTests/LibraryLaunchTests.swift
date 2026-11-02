import XCTest
@testable import MacLooper
import JamCore

final class LibraryLaunchTests: XCTestCase {
    @MainActor func testMissingOwnCopyDoesNotFallBackToAnOldSourceBookmark() async throws {
        let suite = "MacJamsMissingOwn-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json"), own = root.appendingPathComponent("Missing")
        let data = Data(#"{"songs":[{"id":"a","title":"External source","rawData":"Test"}],"playlists":[]}"#.utf8)
        try data.write(to: source)
        defaults.set(try XCTUnwrap(SongLibraryModel.bookmark(source)), forKey: "librarySource")
        let model = SongLibraryModel(defaults: defaults, loadOnLaunch: false, folderOverride: own)
        defer { model.shutdown() }
        await model.refresh()
        XCTAssertNil(model.library); XCTAssertNotNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.destination.path))
        XCTAssertEqual(try Data(contentsOf: source), data)
    }
    @MainActor func testOwnLibraryIsAuthoritativeAndLegacyJustChordsSourceNeverSyncs() async throws {
        let suite = "MacJamsNativeLibrary-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let own = root.appendingPathComponent("Own"), source = root.appendingPathComponent("source.json")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = Data(#"{"songs":[{"id":"a","title":"Own copy","rawData":"[C]Test"}],"playlists":[]}"#.utf8)
        let external = Data(#"{"songs":[{"id":"a","title":"External source","rawData":"[G]Source"}],"playlists":[]}"#.utf8)
        try local.write(to: own.appendingPathComponent("library.json")); try external.write(to: source)
        defaults.set(try XCTUnwrap(SongLibraryModel.bookmark(own)), forKey: "libraryFolder")
        defaults.set(try XCTUnwrap(SongLibraryModel.bookmark(source)), forKey: "librarySource")
        let opened = SongLibraryModel(defaults: defaults, loadOnLaunch: false)
        defer { opened.shutdown() }
        await opened.refresh()
        XCTAssertEqual(opened.library?.songs.first?.title, "Own copy")
        XCTAssertNil(defaults.data(forKey: "librarySource"))
        XCTAssertNil(opened.selectedSongID)
        var draft = SongDraft(song: try XCTUnwrap(opened.library?.songs.first)); draft.title = "Edited in Mac Jams"
        try await opened.save(draft)
        let reopened = SongLibraryModel(defaults: defaults, loadOnLaunch: false)
        defer { reopened.shutdown() }
        await reopened.refresh()
        XCTAssertEqual(reopened.library?.songs.first?.title, "Edited in Mac Jams")
        XCTAssertNil(reopened.selectedSongID)
        XCTAssertEqual(try Data(contentsOf: source), external, "The original JustChords source stays unchanged")
    }

}

extension LibraryLaunchTests {
    @MainActor func testSongSortChoiceSurvivesReopeningWithoutSelectingASong() {
        let suite = "MacJamsSort-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SongLibraryModel(defaults: defaults, loadOnLaunch: false)
        XCTAssertEqual(first.sortOrder.rawValue, "songName")
        first.sortOrder = .artistName
        let reopened = SongLibraryModel(defaults: defaults, loadOnLaunch: false)
        XCTAssertEqual(reopened.sortOrder.rawValue, "artistName")
        XCTAssertNil(reopened.selectedSongID)
        first.shutdown(); reopened.shutdown()
    }
}
