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
}
