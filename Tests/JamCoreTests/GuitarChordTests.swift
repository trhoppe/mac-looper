import XCTest
@testable import JamCore

final class GuitarChordTests: XCTestCase {
    private let catalogue = GuitarChordCatalogue.shared
    private func library() throws -> JustChordsLibrary {
        try JustChordsLibrary(data: Data(#"{"songs":[{"id":"a","title":"Test","rawData":"[C]One [G]two","future":9223372036854775807},{"id":"b","title":"Other","rawData":"[C]Three"}],"playlists":[]}"#.utf8))
    }
    func testOfflineCatalogueAndOpenCShapeAreBundled() throws {
        XCTAssertGreaterThan(catalogue.positionCount, 3000)
        let c = try XCTUnwrap(catalogue.shapes(for: "C").first)
        XCTAssertEqual(c.frets, [-1, 3, 2, 0, 1, 0])
        XCTAssertEqual(c.fingers, [0, 3, 2, 0, 1, 0])
        XCTAssertEqual(c.baseFret, 1)
        XCTAssertTrue(catalogue.groups.flatMap(\.shapes).allSatisfy(\.isValid))
    }
    func testEnharmonicAndQualityAliasesFindTheSameShapes() {
        XCTAssertEqual(catalogue.shapes(for: "Dbm7"), catalogue.shapes(for: "C#m7"))
        XCTAssertFalse(catalogue.shapes(for: "Dbm7").isEmpty)
        XCTAssertEqual(catalogue.shapes(for: "C6/9"), catalogue.shapes(for: "C69"))
        XCTAssertEqual(catalogue.shapes(for: "F♯min7"), catalogue.shapes(for: "F#m7"))
        XCTAssertEqual(catalogue.shapes(for: "CΔ7"), catalogue.shapes(for: "Cmaj7"))
        XCTAssertEqual(catalogue.shapes(for: "Cmajor/G"), catalogue.shapes(for: "C/G"))
        XCTAssertFalse(catalogue.shapes(for: "Ab5").isEmpty)
        XCTAssertTrue(catalogue.shapes(for: "N.C.").isEmpty)
        XCTAssertTrue(catalogue.shapes(for: "Riff A").isEmpty)
    }
    func testSongChordsFollowParserAndDisplayedTransposition() {
        let source = #"""
        {title: [F] is a title}
        {comment: [D] is a comment}
        [C]One [G/B]two [*Fine] [N.C.] \[Am\] [C]again
        {sot}
        [E] e|---0---|
        {eot}
        """#
        XCTAssertEqual(ChordProDocument(source: source).guitarChords, ["C", "G/B"])
        XCTAssertEqual(ChordProDocument(source: source, transpose: 2).guitarChords, ["D", "A/C#"])
    }
    func testIndependentLibraryFiltersAndDashMeansUnrestricted() {
        XCTAssertEqual(catalogue.filtered(root: nil, quality: nil, bass: nil).count, catalogue.groups.count)
        let majorC = catalogue.filtered(root: "C", quality: "major", bass: nil)
        XCTAssertTrue(majorC.contains { $0.name == "C" })
        XCTAssertTrue(majorC.contains { $0.name == "C/E" })
        let withoutSlash = catalogue.filtered(root: "C", quality: "major", bass: nil, includeSlashChords: false)
        XCTAssertEqual(withoutSlash.map(\.name), ["C"])
        XCTAssertEqual(catalogue.filtered(root: nil, quality: nil, bass: nil, includeSlashChords: false).map(\.name),
                       catalogue.groups.filter { $0.bass == nil }.map(\.name))
        let inversion = catalogue.filtered(root: "C", quality: "major", bass: "G")
        XCTAssertFalse(inversion.isEmpty)
        XCTAssertTrue(inversion.allSatisfy { $0.root == "C" && $0.quality == "major" && $0.bass == "G" })
        XCTAssertEqual(catalogue.filtered(root: "Db", quality: nil, bass: nil).map(\.name),
                       catalogue.filtered(root: "C#", quality: nil, bass: nil).map(\.name))
    }
    func testShapeSaveIsSongSpecificAndKeepsOriginalChordProAndUnknownData() throws {
        let original = try library()
        var draft = SongDraft(song: original.songs[0])
        let shape = try XCTUnwrap(catalogue.shapes(for: "C").last)
        draft.chordVoicings["C"] = shape
        let saved = try original.applying(draft)
        let reopened = try JustChordsLibrary(data: saved.originalData)
        XCTAssertEqual(reopened.songs[0].chordVoicings["C"], shape)
        XCTAssertEqual(reopened.songs[0].chordPro, original.songs[0].chordPro)
        XCTAssertEqual(reopened.songs[1], original.songs[1])
        XCTAssertTrue(String(decoding: saved.originalData, as: UTF8.self).contains("9223372036854775807"))
    }
    func testConcurrentDifferentChordChoicesMergeAndSameChordConflicts() throws {
        let original = try library(), c = catalogue.shapes(for: "C"), g = catalogue.shapes(for: "G")
        var first = SongDraft(song: original.songs[0]); first.chordVoicings["C"] = c[1]
        var other = SongDraft(song: original.songs[0]); other.chordVoicings["G"] = g[1]
        let saved = try original.applying(first).applying(other)
        XCTAssertEqual(saved.songs[0].chordVoicings, ["C": c[1], "G": g[1]])
        var conflict = SongDraft(song: original.songs[0]); conflict.chordVoicings["C"] = c[2]
        XCTAssertThrowsError(try saved.applying(conflict))
        var lyrics = SongDraft(song: original.songs[0]); lyrics.artist = "Updated artist"
        XCTAssertEqual(try saved.applying(lyrics).songs[0].chordVoicings, saved.songs[0].chordVoicings)
    }
    func testFileSaveUsesExistingBackupAndRoundTripsChoice() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("library.json"), original = try library()
        try original.originalData.write(to: url)
        var draft = SongDraft(song: original.songs[0]); draft.chordVoicings["C"] = catalogue.shapes(for: "C")[1]
        let saved = try await LibraryFiles(conflictVersions: { _ in [] }).save(draft, to: url)
        XCTAssertEqual(try JustChordsLibrary(data: Data(contentsOf: url)).songs[0].chordVoicings, saved.songs[0].chordVoicings)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Library Backups").path).count, 1)
    }
}
