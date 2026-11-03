import XCTest
@testable import JamCore

final class SongEditingTests: XCTestCase {
    private let legacyFixture = Data(#"{"identity":"original","future":9223372036854775807,"songs":[{"id":"a","title":"Before","artist":"Band","keyChord":{"key":"C","minor":false,"future":"keep"},"tempo":"120","timeSignature":"4/4","duration":"3:45","rawData":"Intro:\n[C]Héllo 🌍 [G]there\ne|--0---|\nB|----1-|","transpose":"D","capo":"2","url":"https://example.com/song","future":{"nested":[true,null,7]}},{"id":"b","title":"Other","rawData":"[Am]Keep me"}],"playlists":[{"id":"p","title":"Set","separateSongSettings":true,"arrangement":[{"type":"song","id":"a","capo":3}]}],"songsTrash":[{"id":"trash"}],"tags":[{"id":"tag","name":"keep"}]}"#.utf8)
    private var fixture: Data { try! JustChordsLibrary(data: legacyFixture).migratingToChordPro().originalData }
    private func library() throws -> JustChordsLibrary { try JustChordsLibrary(data: fixture) }
    private func draft() throws -> SongDraft { SongDraft(song: try library().songs[0]) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testEditingDetailsAndChordProPreservesUnknownDataAndCompatibleTypes() throws {
        var edit = try draft()
        edit.title = "After"; edit.artist = "New band"; edit.key = "F#m"
        edit.tempo = "135"; edit.timeSignature = "6/8"; edit.duration = "4:05"
        edit.chordPro = ChordProSongSource.render(ChordProSongSource(edit.chordPro).values, body: "Verse:\n[F#m]Héllo 🌍 [C#7]world\n{start_of_tab}\ne|--0--2--|\nB|----3---|\n{end_of_tab}\n")
        let original = try library(), changed = try original.applying(edit, modifiedAt: Date(timeIntervalSinceReferenceDate: 1234))
        let song = changed.songs[0]
        XCTAssertEqual(song.id, "a"); XCTAssertEqual(song.title, "After"); XCTAssertEqual(song.artist, "New band")
        XCTAssertEqual(song.originalKey, "F#"); XCTAssertEqual(song.fields["keyChord"]?.object["minor"], .bool(true))
        XCTAssertEqual(song.fields["keyChord"]?.object["future"], .string("keep"))
        XCTAssertNil(song.fields["transpose"])
        XCTAssertEqual(song.fields["tempo"], .string("135")); XCTAssertEqual(song.timeSignature, "6/8")
        XCTAssertEqual(song.duration, "4:05"); XCTAssertEqual(song.chordPro, edit.chordPro)
        XCTAssertEqual(song.fields["date"], .number(1234)); XCTAssertEqual(song.capo, "2")
        XCTAssertEqual(song.fields["future"], original.songs[0].fields["future"])
        XCTAssertEqual(changed.songs[1], original.songs[1]); XCTAssertEqual(changed.playlists, original.playlists)
        XCTAssertEqual(changed.root["songsTrash"], original.root["songsTrash"]); XCTAssertEqual(changed.root["tags"], original.root["tags"])
        XCTAssertTrue(String(decoding: changed.originalData, as: UTF8.self).contains("9223372036854775807"))
    }
    func testNumericIDsAndUnknownKeyNumbersRemainCompatible() throws {
        let input = Data(#"{"songs":[{"id":7,"title":"Numeric ID","keyChord":{"key":"C","minor":false,"future":9223372036854775807},"rawData":"[C]Test"}],"playlists":[]}"#.utf8)
        let original = try JustChordsLibrary(data: input)
        var draft = SongDraft(song: original.songs[0]); draft.key = "Am"
        let edited = try original.applying(draft)
        XCTAssertEqual(edited.songs[0].id, "7")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: edited.originalData) as? [String: Any])
        let songs = try XCTUnwrap(root["songs"] as? [[String: Any]])
        let key = try XCTUnwrap(songs[0]["keyChord"] as? [String: Any])
        XCTAssertEqual((key["future"] as? NSNumber)?.stringValue, "9223372036854775807")
    }
    func testUnchangedDraftIsByteIdenticalAndLeavesExistingTransposeAndRawTabsAlone() throws {
        let original = try library(), edit = try draft()
        XCTAssertFalse(edit.hasChanges); XCTAssertNil(edit.validationError)
        XCTAssertEqual(try original.applying(edit).originalData, fixture)
        var metadataOnly = edit; metadataOnly.artist = "Edited artist"
        let updated = try original.applying(metadataOnly)
        XCTAssertEqual(ChordProSongSource(updated.songs[0].chordPro).body, ChordProSongSource(original.songs[0].chordPro).body)
        XCTAssertEqual(updated.songs[0].fields["transpose"], .string("D"))
    }
    func testOptionalFieldsCanBeClearedWithoutRemovingUnrelatedData() throws {
        var edit = try draft(); edit.key = ""; edit.tempo = ""; edit.timeSignature = ""; edit.duration = ""
        let song = try library().applying(edit).songs[0]
        for field in ["keyChord", "transpose", "tempo", "timeSignature", "duration"] { XCTAssertNil(song.fields[field]) }
        XCTAssertEqual(song.capo, "2"); XCTAssertEqual(song.chordPro, edit.chordPro)
    }
    func testInvalidMetadataReportsUsefulErrorsWhileDraftRemainsEditable() throws {
        var edit = try draft(); edit.title = "  "
        XCTAssertNotNil(edit.validationError)
        edit = try draft(); edit.key = "H#"; XCTAssertNotNil(edit.validationError)
        edit = try draft(); edit.tempo = "NaN"; XCTAssertNotNil(edit.validationError)
        edit = try draft(); edit.tempo = "-10"; XCTAssertNotNil(edit.validationError)
        edit = try draft(); edit.timeSignature = "4/3"; XCTAssertNotNil(edit.validationError)
        edit = try draft(); edit.duration = "3:75"; XCTAssertNotNil(edit.validationError)
        edit.duration = "1:02:03"; XCTAssertNil(edit.validationError)
        edit.duration = "3:05"; XCTAssertNil(edit.validationError)
    }
    func testDifferentFieldsAndSongsFromAnotherDeviceMergeWithoutDataLoss() throws {
        let original = try library()
        var first = SongDraft(song: original.songs[0]); first.artist = "Updated remotely"
        var remote = try original.applying(first)
        var other = SongDraft(song: original.songs[1]); other.title = "Other changed remotely"
        remote = try remote.applying(other)
        var local = SongDraft(song: original.songs[0]); local.title = "My title"
        let merged = try remote.applying(local)
        XCTAssertEqual(merged.songs[0].title, "My title"); XCTAssertEqual(merged.songs[0].artist, "Updated remotely")
        XCTAssertEqual(merged.songs[1].title, "Other changed remotely")
    }
    func testConflictingFieldOrMissingSongNeverOverwritesLatestVersion() throws {
        let original = try library()
        var first = try draft(); first.chordPro = ChordProSongSource.render(ChordProSongSource(first.chordPro).values, body: "[D]Remote")
        let latest = try original.applying(first)
        var stale = try draft(); stale.chordPro = ChordProSongSource.render(ChordProSongSource(stale.chordPro).values, body: "[G]Local")
        XCTAssertThrowsError(try latest.applying(stale)) { XCTAssertTrue($0 is SongEditError) }
        XCTAssertEqual(ChordProSongSource(stale.chordPro).body, "[G]Local")
        let removed = try JustChordsLibrary(data: Data(#"{"songs":[],"playlists":[]}"#.utf8))
        XCTAssertThrowsError(try removed.applying(stale))
        XCTAssertEqual(try latest.applying(first).originalData, latest.originalData, "A converged edit must not create another version")
    }
    func testCoordinatedSaveMakesExactBackupAndCanReopen() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json"); try fixture.write(to: url)
        var edit = try draft(); edit.title = "Saved"; edit.chordPro += "\n[G]Added\tspaces  stay"
        let io = LibraryFiles(), saved = try await io.save(edit, to: url)
        let reopened = try await io.read(url)
        XCTAssertEqual(saved.originalData, reopened.originalData); XCTAssertEqual(reopened.songs[0].chordPro, edit.chordPro)
        let backups = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("Library Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: backups[0]), fixture)
    }
    func testNoopAndFailedConflictDoNotCreateBackupsOrChangeFile() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json"); try fixture.write(to: url)
        let io = LibraryFiles(); _ = try await io.save(draft(), to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Library Backups").path))
        var remote = try draft(); remote.title = "Remote"
        let latest = try library().applying(remote); try latest.originalData.write(to: url)
        var local = try draft(); local.title = "Local"
        do { _ = try await io.save(local, to: url); XCTFail("Expected conflict") } catch SongEditError.conflict { }
        XCTAssertEqual(try Data(contentsOf: url), latest.originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Library Backups").path))
    }
    func testConcurrentDifferentSongSavesKeepBothChanges() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json"); try fixture.write(to: url)
        let original = try library()
        var one = SongDraft(song: original.songs[0]); one.title = "One edited"
        var two = SongDraft(song: original.songs[1]); two.title = "Two edited"
        let io1 = LibraryFiles(), io2 = LibraryFiles()
        let first = one, second = two
        async let a = io1.save(first, to: url)
        async let b = io2.save(second, to: url)
        _ = try await (a, b)
        let result = try await io1.read(url)
        XCTAssertEqual(result.songs.map(\.title), ["One edited", "Two edited"])
    }
    func testOriginalJustChordsContainerIsProtectedIncludingSymlinks() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("iCloud~online~justchords~JustChords/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let url = source.appendingPathComponent("library.json"); try fixture.write(to: url)
        let link = dir.appendingPathComponent("Alias"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertTrue(LibraryFiles.isProtectedLibrary(link.appendingPathComponent("library.json")))
        var edit = try draft(); edit.title = "Blocked"
        do { _ = try await LibraryFiles().save(edit, to: url); XCTFail("Protected original must not be edited") } catch SongEditError.protectedLibrary { }
        XCTAssertEqual(try Data(contentsOf: url), fixture)
    }
    func testSyntaxHighlightingUsesUTF16AndLeavesEscapedBracketsAndTabsPlain() {
        let text = "Intro:\n🌍 [C]Words \\[literal] [G7]other\n{start_of_tab}\ne|--[0]--|\n{end_of_tab}\n"
        let spans = ChordProSyntax.spans(in: text), ns = text as NSString
        XCTAssertEqual(spans.filter { $0.style == .chord }.map { ns.substring(with: $0.range) }, ["[C]", "[G7]"])
        XCTAssertEqual(spans.filter { $0.style == .section }.map { ns.substring(with: $0.range) }, ["Intro:"])
    }
}

extension SongEditingTests {
    func testMetadataFieldsAndRawDirectivesAreOneEditableValue() throws {
        var edit = try draft()
        edit.title = "Canonical title"; edit.tempo = "142"
        XCTAssertTrue(edit.chordPro.contains("{title: Canonical title}"))
        XCTAssertTrue(edit.chordPro.contains("{tempo: 142}"))
        edit.chordPro = edit.chordPro.replacingOccurrences(of: "{tempo: 142}", with: "{meta: tempo 135}")
            .replacingOccurrences(of: "{title: Canonical title}", with: "{t Raw title}")
        XCTAssertEqual(edit.tempo, "135"); XCTAssertEqual(edit.title, "Raw title")
        let saved = try library().applying(edit).songs[0]
        XCTAssertEqual(saved.title, "Raw title"); XCTAssertEqual(saved.tempo, 135)
        XCTAssertEqual(saved.fields["title"], .string("Raw title")); XCTAssertEqual(saved.fields["tempo"], .string("135"))
        XCTAssertTrue(saved.isChordProNative)
    }
    func testNativeSourceWinsOverStaleCompatibilityFieldsAndClearStaysCleared() throws {
        let fields: [String: JSONValue] = ["id": .string("a"), "macJamsChordProVersion": .number(1),
            "title": .string("Stale"), "artist": .string("Old"), "tempo": .string("90"),
            "rawData": .string("{title: Source title}\n{artist: Source artist}\n{tempo: 130}\n[C]Words")]
        let song = LibrarySong(fields: fields)
        XCTAssertEqual(song.title, "Source title"); XCTAssertEqual(song.artist, "Source artist"); XCTAssertEqual(song.tempo, 130)
        var edit = SongDraft(song: song); edit.tempo = ""
        var cleared = fields; cleared["rawData"] = .string(edit.chordPro)
        XCTAssertNil(LibrarySong(fields: cleared).tempo, "Removing a source directive must not revive the old JSON copy")
        XCTAssertEqual(try edit.changes()["tempo"], .null)
    }
    func testLegacyConversionPreservesMusicAndCreatesExplicitSectionsAndTabsOnce() throws {
        let original = try JustChordsLibrary(data: legacyFixture)
        let migrated = try original.migratingToChordPro(), song = migrated.songs[0]
        XCTAssertTrue(song.isChordProNative)
        XCTAssertEqual(song.title, original.songs[0].title); XCTAssertEqual(song.tempo, original.songs[0].tempo)
        XCTAssertEqual(song.displayKey, original.songs[0].displayKey); XCTAssertEqual(song.transposition, 2)
        XCTAssertTrue(song.chordPro.contains("{title: Before}")); XCTAssertTrue(song.chordPro.contains("{key: C}"))
        XCTAssertTrue(song.chordPro.contains("{start_of_verse: label=\"Intro\"}"))
        XCTAssertTrue(song.chordPro.contains("{start_of_tab}\ne|--0---|\nB|----1-|\n{end_of_tab}"))
        let before = ChordProDocument(source: original.songs[0].chordPro), after = ChordProDocument(source: song.chordPro)
        XCTAssertEqual(before.lines.flatMap(\.fragments), after.lines.flatMap(\.fragments))
        XCTAssertEqual(before.lines.filter { $0.kind == .tablature }.map(\.text), after.lines.filter { $0.kind == .tablature }.map(\.text))
        XCTAssertEqual(migrated.playlists, original.playlists); XCTAssertEqual(migrated.root["songsTrash"], original.root["songsTrash"])
        XCTAssertEqual(migrated.root["tags"], original.root["tags"])
        XCTAssertTrue(String(decoding: migrated.originalData, as: UTF8.self).contains("9223372036854775807"))
        XCTAssertEqual(try migrated.migratingToChordPro().originalData, migrated.originalData)
    }
    func testConversionBackupIsExactAndSecondLaunchDoesNotWriteAgain() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json"); try legacyFixture.write(to: url)
        let io = LibraryFiles(), first = try await io.prepareChordProLibrary(at: url)
        let backups = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("Library Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1); XCTAssertTrue(backups[0].lastPathComponent.hasPrefix("library-before-chordpro-"))
        XCTAssertEqual(try Data(contentsOf: backups[0]), legacyFixture)
        let second = try await io.prepareChordProLibrary(at: url)
        XCTAssertEqual(first.originalData, second.originalData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Library Backups").path).count, 1)
    }
    func testConversionDoesNotReplaceExistingDirectivesOrTouchLaterModulations() throws {
        let source = "{t: Existing}\n{meta: tempo 150}\n{key: C}\n{sov: Verse}\n[C]Words\n{key: D}\n{tempo: 160}\n[D]More\n{eov}"
        let song = LibrarySong(fields: ["id": .string("x"), "title": .string("Stale"), "tempo": .string("90"), "rawData": .string(source)])
        let seeded = ChordProSongSource.seeded(from: song)
        XCTAssertEqual(ChordProSongSource(seeded).first("title"), "Existing")
        XCTAssertEqual(ChordProSongSource(seeded).first("tempo"), "150")
        var edit = SongDraft(song: song); edit.key = "E"
        XCTAssertTrue(edit.chordPro.contains("{key: D}\n{tempo: 160}"))
        XCTAssertEqual(edit.key, "E"); XCTAssertEqual(edit.tempo, "150")
    }
    func testBodyEditAndIndependentMetadataEditMergeAndSameDirectiveConflicts() throws {
        let original = try library()
        var remote = try draft(); remote.chordPro += "\n[G]New body"
        let latest = try original.applying(remote)
        var local = try draft(); local.tempo = "140"
        let merged = try latest.applying(local)
        XCTAssertEqual(merged.songs[0].tempo, 140); XCTAssertTrue(merged.songs[0].chordPro.contains("[G]New body"))
        var other = try draft(); other.tempo = "150"
        XCTAssertThrowsError(try original.applying(local).applying(other))
    }
    func testMalformedOrProtectedLibraryCannotBeMigrated() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json"), broken = Data("{partial".utf8)
        try broken.write(to: url)
        do { _ = try await LibraryFiles().prepareChordProLibrary(at: url); XCTFail("Invalid JSON must fail") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), broken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Library Backups").path))
        let protected = dir.appendingPathComponent("iCloud~online~justchords~JustChords/library.json")
        try FileManager.default.createDirectory(at: protected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyFixture.write(to: protected)
        do { _ = try await LibraryFiles().prepareChordProLibrary(at: protected); XCTFail("Original source must stay untouched") } catch SongEditError.protectedLibrary { }
        XCTAssertEqual(try Data(contentsOf: protected), legacyFixture)
    }
}
