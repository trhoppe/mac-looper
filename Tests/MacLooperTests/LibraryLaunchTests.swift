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

extension LibraryLaunchTests {
    @MainActor func testLaunchRestoresFolderAndWaitsForNewCloudChordsBeforePublishing() async throws {
        let suite = "MacJamsCloudLaunch-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // Isolate both preferences and disk data from the real library.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("library.json")
        let cached = Data(#"{"songs":[{"id":"a","title":"Song","rawData":"[C]Old chords"}],"playlists":[]}"#.utf8)
        let updated = Data(#"{"songs":[{"id":"a","title":"Song","rawData":"[G]New chords"}],"playlists":[]}"#.utf8)
        try cached.write(to: url)
        defaults.set(try XCTUnwrap(SongLibraryModel.bookmark(root)), forKey: "libraryFolder")
        let held = Suspension()
        let io = LibraryFiles(refreshCloudFile: { destination in
            XCTAssertEqual(destination.standardizedFileURL, url.standardizedFileURL)
            if !held.entered { await held.wait() }
        })
        let model = SongLibraryModel(defaults: defaults, readTracks: { _ in [:] }, io: io)
        defer { model.shutdown() }
        for _ in 0..<1000 where !held.entered { await Task.yield() }
        XCTAssertTrue(held.entered); XCTAssertTrue(model.syncing); XCTAssertNil(model.library)
        try updated.write(to: url, options: .atomic)
        held.resume()
        await model.refresh()
        XCTAssertTrue(model.library?.songs.first?.chordPro.contains("[G]New chords") == true)
        XCTAssertNil(model.error); XCTAssertNil(model.selectedSongID)
    }
    @MainActor func testUnavailableCloudUsesCachedChordsWithWarningAndNextOpenRefreshClearsIt() async throws {
        let suite = "MacJamsCloudOffline-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("library.json")
        let cached = Data(#"{"songs":[{"id":"a","title":"Cached","rawData":"[C]Old chords"}],"playlists":[]}"#.utf8)
        try cached.write(to: url)
        var offline = true
        let io = LibraryFiles(refreshCloudFile: { _ in
            if offline { throw LibraryCloudRefreshError.unavailable("Offline") }
        })
        let model = SongLibraryModel(defaults: defaults, loadOnLaunch: false, folderOverride: root, readTracks: { _ in [:] }, io: io)
        defer { model.shutdown() }
        await model.refresh()
        XCTAssertTrue(model.library?.songs.first?.chordPro.contains("[C]Old chords") == true)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.status.contains("iCloud update pending"))
        XCTAssertEqual(try Data(contentsOf: url), cached, "Offline refresh must not migrate the stale file")
        offline = false
        try Data(#"{"songs":[{"id":"a","title":"Updated","rawData":"[G]New chords"}],"playlists":[]}"#.utf8).write(to: url, options: .atomic)
        await model.refresh()
        XCTAssertTrue(model.library?.songs.first?.chordPro.contains("[G]New chords") == true)
        XCTAssertNil(model.error); XCTAssertFalse(model.status.contains("pending"))
    }
}
