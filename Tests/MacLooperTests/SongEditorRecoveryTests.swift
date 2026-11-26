import XCTest
import JamCore
@testable import MacLooper

final class SongEditorRecoveryTests: XCTestCase {
    @MainActor func testClosingAndReopeningEditorRestoresDraftThenDiscardRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SongDraftRecoveryStore(folder: root.appendingPathComponent("Recovery"))
        let library = SongLibraryModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, loadOnLaunch: false,
            folderOverride: root.appendingPathComponent("Own"), recoveryStore: store)
        defer { library.shutdown() }
        let song = LibrarySong(fields: ["id": .string("a"), "title": .string("Original"), "rawData": .string("[C]Words")])
        let editor = SongEditorModel(draft: SongDraft(song: song), library: library)
        await editor.restore()
        editor.draft.title = "Unsaved name"
        editor.draft.savedLoopName = "Practice.jamloop"
        editor.draft.backingImport = SongBackingImport(bookmark: Data([1]), name: "Track.wav")
        editor.draft.chordPro += "\n[G]New line"
        try await editor.keepForLater()
        XCTAssertEqual(library.recoveredDrafts.count, 1)
        let reopened = SongEditorModel(draft: SongDraft(song: song), library: library)
        await reopened.restore()
        XCTAssertTrue(reopened.recovered)
        XCTAssertEqual(reopened.draft, editor.draft)
        try await reopened.clearRecovery()
        let remaining = try await store.drafts(in: library.destination)
        XCTAssertTrue(remaining.isEmpty)
    }
    @MainActor func testFailedRecoveryWriteCannotCloseEditorClaimingDraftWasKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SongDraftRecoveryStore(folder: root.appendingPathComponent("Not a folder"))
        let library = SongLibraryModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, loadOnLaunch: false,
            folderOverride: root.appendingPathComponent("Own"), recoveryStore: store)
        defer { library.shutdown() }
        let song = LibrarySong(fields: ["id": .string("a"), "title": .string("Original"), "rawData": .string("[C]Words")])
        let editor = SongEditorModel(draft: SongDraft(song: song), library: library)
        await editor.restore(); editor.draft.title = "Still in editor"
        do { try await editor.keepForLater(); XCTFail("Must report failure and retain the editor") } catch { }
        XCTAssertNotNil(editor.recoveryError)
        XCTAssertEqual(editor.draft.title, "Still in editor")
    }
    @MainActor func testSongSaveResolvesBackingBookmarkAndHonorsLegacyRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Example.wav")
        try Data([1, 2, 3]).write(to: source)
        let legacy = root.appendingPathComponent("Legacy.wav")
        try Data([4]).write(to: legacy)
        let json = #"{"songs":[{"id":"a","rawData":"{title: Song}","macJamsChordProVersion":1}],"playlists":[]}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("library.json"))
        let library = SongLibraryModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, loadOnLaunch: false,
            folderOverride: root, readTracks: { _ in ["a": legacy] })
        defer { library.shutdown() }
        await library.refresh()
        XCTAssertEqual(library.backingURL(songID: "a"), legacy)

        var removal = SongDraft(song: try XCTUnwrap(library.songs.first))
        removal.backingTrackPath = ""
        try await library.save(removal)
        XCTAssertNil(library.backingURL(songID: "a"))

        var attachment = SongDraft(song: try XCTUnwrap(library.songs.first))
        attachment.backingImport = SongBackingImport(bookmark: try XCTUnwrap(SongLibraryModel.bookmark(source)), name: source.lastPathComponent)
        try await library.save(attachment)
        let copied = try XCTUnwrap(library.backingURL(songID: "a"))
        XCTAssertEqual(copied.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source))
    }

    @MainActor func testNewSongSaveSelectsCreatedSongAndRecoversItsPlaylists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"songs":[],"playlists":[{"id":"p","title":"Acoustic Songs","arrangement":[]}]}"#.utf8).write(to: root.appendingPathComponent("library.json"))
        let library = SongLibraryModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, loadOnLaunch: false, folderOverride: root,
            recoveryStore: SongDraftRecoveryStore(folder: root.appendingPathComponent("Recovery")))
        defer { library.shutdown() }
        await library.refresh(); library.playlistID = "p"; library.query = "old search"
        let editor = SongEditorModel(draft: SongDraft(newSongID: "new", playlistIDs: ["p"]), library: library)
        await editor.restore(); editor.draft.title = "New song"
        try await editor.keepForLater()
        let recovered = try XCTUnwrap(library.recoveredDrafts.first?.draft)
        XCTAssertTrue(recovered.isNew); XCTAssertEqual(recovered.playlistIDs, ["p"])
        try await library.save(recovered)
        XCTAssertEqual(library.selectedSongID, "new"); XCTAssertEqual(library.playlistID, "p"); XCTAssertTrue(library.query.isEmpty)
        XCTAssertEqual(library.songs.map(\.id), ["new"])
        try await editor.clearRecovery()
        XCTAssertTrue(library.recoveredDrafts.isEmpty)
    }

}
