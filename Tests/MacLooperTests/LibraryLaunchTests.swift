import XCTest
@testable import MacLooper

final class LibraryLaunchTests: XCTestCase {
    @MainActor func testLibrarySyncsAtLaunchAndDoesNotPollWhileOpen() async throws {
        let suite = "MacLooperLibraryLaunch-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let own = root.appendingPathComponent("Own"), source = root.appendingPathComponent("source.json")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Data(#"{"songs":[{"id":"a","title":"Before","rawData":"[C]Test"}],"playlists":[],"tags":[]}"#.utf8)
        let after = Data(#"{"songs":[{"id":"a","title":"After","rawData":"[G]Test"}],"playlists":[],"tags":[]}"#.utf8)
        try before.write(to: source)
        defaults.set(try XCTUnwrap(SongLibraryModel.bookmark(own)), forKey: "libraryFolder")
        defaults.set(try XCTUnwrap(SongLibraryModel.bookmark(source)), forKey: "librarySource")
        let opened = SongLibraryModel(defaults: defaults)
        defer { opened.shutdown() }
        for _ in 0..<200 where opened.library == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(opened.library?.songs.first?.title, "Before")
        try after.write(to: source, options: .atomic)
        try await Task.sleep(for: .milliseconds(3250))
        XCTAssertEqual(opened.library?.songs.first?.title, "Before")
        XCTAssertEqual(try Data(contentsOf: own.appendingPathComponent("library.json")), before)
        let reopened = SongLibraryModel(defaults: defaults)
        defer { reopened.shutdown() }
        for _ in 0..<200 where reopened.library == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reopened.library?.songs.first?.title, "After")
        XCTAssertEqual(try Data(contentsOf: own.appendingPathComponent("library.json")), after)
        XCTAssertEqual(try Data(contentsOf: source), after)
    }
}
