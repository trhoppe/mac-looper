import XCTest
@testable import JamCore

final class LoopFilesTests: XCTestCase {
    private func library() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
    private func take() throws -> Data {
        try SavedLoop(sampleRate: 48000, bpm: 93, bars: 4,
                      left: Array(repeating: 0.3, count: 1501), right: Array(repeating: -0.1, count: 1501)).encoded()
    }
    func testTwoClientsShareFilesAndDuplicateNamesNeverReplaceTakes() async throws {
        let folder = try library(); defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = folder.appendingPathComponent("library.json"), sentinel = Data("leave chord library alone".utf8)
        try sentinel.write(to: manifest)
        let mac = LoopFiles(), ipad = LoopFiles(), data = try take()
        let first = try await mac.save(data, name: "Funky Jam", in: folder)
        let initial = try await ipad.list(in: folder)
        XCTAssertEqual(initial.map(\.name), ["Funky Jam"])
        let recalled = try await ipad.read(initial[0].url)
        XCTAssertEqual(recalled.bpm, 93); XCTAssertEqual(recalled.frames, 1501)
        let second = try await ipad.save(data, name: "funky jam.jamloop", in: folder)
        XCTAssertEqual(second.name, "funky jam (2)")
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try Data(contentsOf: first.url), data)
        let all = try await mac.list(in: folder)
        XCTAssertEqual(all.count, 2); XCTAssertEqual(try Data(contentsOf: manifest), sentinel)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: LoopFiles.folder(in: folder).path).contains { $0.hasSuffix(".pending") })
    }
    func testCatalogueSortsNaturallyAndIncludesNotDownloadedPlaceholders() async throws {
        let folder = try library(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = LoopFiles(), data = try take()
        _ = try await store.save(data, name: "Jam 10", in: folder)
        _ = try await store.save(data, name: "Jam 2", in: folder)
        let loops = LoopFiles.folder(in: folder)
        try Data().write(to: loops.appendingPathComponent(".Remote Jam.jamloop.icloud"))
        try Data().write(to: loops.appendingPathComponent("ignore.txt"))
        try FileManager.default.createDirectory(at: loops.appendingPathComponent("folder.jamloop"), withIntermediateDirectories: false)
        let entries = try await store.list(in: folder)
        XCTAssertEqual(entries.map(\.name), ["Jam 2", "Jam 10", "Remote Jam"])
        XCTAssertEqual(entries.last?.url.lastPathComponent, "Remote Jam.jamloop")
    }
    func testReadWaitsForDownloadBeforeDecoding() async throws {
        let folder = try library(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Remote.jamloop"), data = try take()
        let store = LoopFiles(refreshCloudFile: { target in
            try await Task.sleep(for: .milliseconds(10))
            try data.write(to: target, options: .atomic)
        })
        let result = try await store.read(url)
        XCTAssertEqual(result.frames, 1501); XCTAssertEqual(result.bpm, 93)
        let unavailable = LoopFiles(refreshCloudFile: { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await unavailable.read(url); XCTFail("Must not silently return a stale cached take") }
        catch { XCTAssertTrue(error.localizedDescription.contains("iCloud")) }
    }
    func testInvalidNamesDataAndUnavailableFoldersDoNotWrite() async throws {
        let folder = try library(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = LoopFiles(), data = try take()
        let empty = try await store.list(in: folder)
        XCTAssertTrue(empty.isEmpty)
        for name in ["", "  ", "../escape", "a/b", "a\\b", "a:b", ".hidden", "a\nb", String(repeating: "x", count: 141)] {
            do { _ = try await store.save(data, name: name, in: folder); XCTFail(name) } catch { }
        }
        do { _ = try await store.save(Data("broken".utf8), name: "Bad", in: folder); XCTFail() } catch { }
        do { _ = try await store.save(data, name: "Bad", in: folder.appendingPathComponent("missing")); XCTFail() } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: LoopFiles.folder(in: folder).path))
    }
    func testUnicodeNamesAndSymlinkSafety() async throws {
        let folder = try library(), outside = try library()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside) }
        let store = LoopFiles(), data = try take()
        _ = try await store.save(data, name: "Café", in: folder)
        let duplicate = try await store.save(data, name: "Cafe\u{301}", in: folder)
        XCTAssertEqual(duplicate.name, "Café (2)")
        let linked = outside.appendingPathComponent("Loops")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: LoopFiles.folder(in: folder))
        do { _ = try await store.save(data, name: "Unexpected", in: outside); XCTFail() } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: LoopFiles.folder(in: folder).appendingPathComponent("Unexpected.jamloop").path))
    }
}
