import XCTest
@testable import JamCore

final class RecoveryAndConflictTests: XCTestCase {
    private func library(_ title: String) throws -> JustChordsLibrary {
        try JustChordsLibrary(data: Data("{\"songs\":[{\"id\":\"a\",\"title\":\"\(title)\",\"rawData\":\"[C]Test\"}],\"playlists\":[]}".utf8))
    }
    func testRecoveryRetainsOriginalForMergeAndIsScopedToLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SongDraftRecoveryStore(folder: root)
        let destination = root.appendingPathComponent("A/library.json")
        var draft = SongDraft(song: try library("Original").songs[0]); draft.title = "My edit"
        try await store.write(RecoveredSongDraft(draft: draft, library: destination), library: destination, songID: draft.id, sequence: 1)
        let reopened = SongDraftRecoveryStore(folder: root)
        let recovered = try await reopened.drafts(in: destination)
        XCTAssertEqual(recovered.first?.draft, draft)
        let other = try await reopened.drafts(in: root.appendingPathComponent("B/library.json"))
        XCTAssertTrue(other.isEmpty)
        try await store.write(nil, library: destination, songID: draft.id, sequence: 3)
        try await store.write(RecoveredSongDraft(draft: draft, library: destination), library: destination, songID: draft.id, sequence: 2)
        let cleared = try await reopened.drafts(in: destination)
        XCTAssertTrue(cleared.isEmpty, "A late queued write cannot resurrect discarded edits")
    }
    func testUnresolvedVersionsBlockSaveAndMigrationAndKeepExactCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("library.json")
        let current = try library("Current"), alternate = try library("Other device")
        try current.originalData.write(to: destination)
        let version = LibraryConflictVersion(id: "other", data: alternate.originalData)
        let io = LibraryFiles(conflictVersions: { _ in [version] })
        let loaded = try await io.prepareChordProLibrary(at: destination)
        XCTAssertEqual(loaded.originalData, current.originalData)
        var edit = SongDraft(song: current.songs[0]); edit.title = "Edit"
        do { _ = try await io.save(edit, to: destination); XCTFail("Must refuse unresolved versions") }
        catch SongEditError.unresolvedCloudConflict { }
        XCTAssertEqual(try Data(contentsOf: destination), current.originalData)
        let copies = try await io.conflictCopies(at: destination)
        XCTAssertEqual(copies.count, 2)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Library Conflicts"), includingPropertiesForKeys: nil)
        let bytes = try backups.map { try Data(contentsOf: $0) }
        XCTAssertTrue(bytes.contains(current.originalData)); XCTAssertTrue(bytes.contains(alternate.originalData))
    }
    func testExplicitConflictChoicePreservesAllCopiesAndRejectsStaleReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("library.json")
        let current = try library("Current"), alternate = try library("Other")
        try current.originalData.write(to: destination)
        let version = LibraryConflictVersion(id: "other", data: alternate.originalData)
        // This test's synchronous callbacks execute only on LibraryFiles' actor.
        var resolved: [String] = []
        let io = LibraryFiles(conflictVersions: { _ in [version] }, markConflictResolved: { v, url in
            XCTAssertEqual(try JustChordsLibrary(data: Data(contentsOf: url)).songs[0].title, "Other")
            resolved.append(v.id)
        })
        let copies = try await io.conflictCopies(at: destination)
        let updated = try await io.resolveConflict(using: "other", expected: copies, at: destination)
        XCTAssertEqual(updated.songs[0].title, "Other"); XCTAssertEqual(resolved, ["other"])
        do { _ = try await io.resolveConflict(using: "current", expected: copies, at: destination); XCTFail("Stale review must not overwrite") }
        catch SongEditError.conflictsChanged { }
        XCTAssertEqual(try Data(contentsOf: destination), updated.originalData)
    }
}

extension RecoveryAndConflictTests {
    func testDamagedRecoveryRecordIsRetainedWithoutHidingGoodDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Library/library.json")
        let store = SongDraftRecoveryStore(folder: root)
        let damaged = root.appendingPathComponent("damaged.json"), bytes = Data("invalid JSON".utf8)
        try bytes.write(to: damaged)
        var draft = SongDraft(song: LibrarySong(fields: ["id": .string("a"), "title": .string("Song"), "rawData": .string("Words")]))
        draft.title = "Recover me"
        try await store.write(RecoveredSongDraft(draft: draft, library: destination), library: destination, songID: draft.id, sequence: 1)
        let recovered = try await store.drafts(in: destination)
        XCTAssertEqual(recovered.first?.draft.title, "Recover me")
        XCTAssertEqual(try Data(contentsOf: damaged), bytes)
    }
}
