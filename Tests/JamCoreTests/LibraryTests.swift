import XCTest
@testable import JamCore
final class LibraryTests: XCTestCase {
    let fixture = Data(#"{"identity":"keep","dataVersion":"original","songs":[{"id":"one","title":"First","rawData":"[C]Hello [G/B]world","keyChord":{"key":"C","minor":false},"unknown":{"n":123,"list":[true,null,"x"]}},{"id":"two","title":"Second","rawData":"[Am]Hi"}],"playlists":[{"id":"list","title":"Set","separateSongSettings":true,"arrangement":[{"id":"two","index":"entry1","type":"song"},{"id":"missing","type":"song"},{"id":"one","type":"song","transpose":"D","capo":2}]}],"songsTrash":[{"anything":"preserved"}],"tags":[],"future":7}"#.utf8)
    func testExactBytePreservationUnknownFieldsTrashAndOrdering() throws {
        let library = try JustChordsLibrary(data: fixture)
        XCTAssertEqual(library.originalData, fixture)
        XCTAssertEqual(library.root["identity"]?.text, "keep")
        XCTAssertEqual(library.root["songsTrash"]?.array.count, 1)
        XCTAssertEqual(library.songs(in: "list").map(\.id), ["two", "one"])
        let adjusted = library.songs(in: "list")[1]
        XCTAssertEqual(adjusted.transposition, 2); XCTAssertEqual(adjusted.capo, "2")
        XCTAssertEqual(library.songs[0].fields["unknown"]?.object["list"]?.array.count, 3)
    }
    func testIncompleteAndDuplicateSongsAreRejected() throws {
        XCTAssertThrowsError(try JustChordsLibrary(data: Data("{}".utf8)))
        XCTAssertThrowsError(try JustChordsLibrary(data: Data(#"{"songs":[{"id":"a","rawData":"x"},{"id":"a","rawData":"y"}],"playlists":[]}"#.utf8)))
    }
    func testMirrorIsLosslessAndNeverOverwritesSource() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json"), copy = dir.appendingPathComponent("mirror/library.json")
        try fixture.write(to: source)
        let io = LibraryFiles(), library = try await io.read(source)
        try await io.mirror(library, to: copy, source: source)
        XCTAssertEqual(try Data(contentsOf: source), fixture); XCTAssertEqual(try Data(contentsOf: copy), fixture)
        do { try await io.mirror(library, to: source, source: source); XCTFail("Source must be read-only") } catch LibraryError.sameSourceAndDestination { }
    }
    func testMalformedUpdateLeavesLastGoodCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json"), copy = dir.appendingPathComponent("copy.json")
        let io = LibraryFiles(), library = try JustChordsLibrary(data: fixture)
        try await io.mirror(library, to: copy, source: source)
        try Data("{partial".utf8).write(to: source)
        do { _ = try await io.read(source); XCTFail("Partial JSON must fail") } catch { }
        XCTAssertEqual(try Data(contentsOf: copy), fixture)
    }
}

extension LibraryTests {
    func testBackingTracksCopyAndPortableIndexDoNotChangeLibraryJSON() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Backing.wav"), own = root.appendingPathComponent("Mac Looper")
        let bytes = Data([0,1,2,3,4]); try bytes.write(to: audio)
        let io = LibraryFiles(), library = try JustChordsLibrary(data: fixture)
        try await io.mirror(library, to: own.appendingPathComponent("library.json"), source: nil)
        let copied = try await io.attachBacking(audio, songID: "song-one", in: own)
        let links = try await io.backingTracks(in: own)
        XCTAssertEqual(links["song-one"], copied)
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
        XCTAssertEqual(try Data(contentsOf: own.appendingPathComponent("library.json")), fixture)
        XCTAssertTrue(copied.path.hasPrefix(own.path + "/"))
    }
    func testBackingManifestCannotEscapeLibraryFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"bad":"../outside.mp3","good":"Backing Tracks/ok.mp3"}"#.utf8).write(to: dir.appendingPathComponent("backing-tracks.json"))
        let links = try await LibraryFiles().backingTracks(in: dir)
        XCTAssertNil(links["bad"]); XCTAssertNotNil(links["good"])
    }
}

extension LibraryTests {
    func testBackingManifestRejectsSymlinkAndAbsolutePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let own = root.appendingPathComponent("Own"), outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: own.appendingPathComponent("Escape"), withDestinationURL: outside)
        try Data(#"{"symlink":"Escape/file.wav","absolute":"/tmp/file.wav","valid":"Backing Tracks/file.wav"}"#.utf8).write(to: own.appendingPathComponent("backing-tracks.json"))
        let links = try await LibraryFiles().backingTracks(in: own)
        XCTAssertNil(links["symlink"]); XCTAssertNil(links["absolute"])
        XCTAssertEqual(links["valid"], own.appendingPathComponent("Backing Tracks/file.wav"))
    }
}
