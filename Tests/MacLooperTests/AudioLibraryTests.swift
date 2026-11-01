import XCTest
@testable import MacLooper

final class AudioLibraryTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    @discardableResult private func put(_ relative: String) throws -> URL {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }
    func testRecursesGroupsRootAndFullRelativeSubdirectoryAndNaturallySorts() throws {
        try put("Root.WAV"); try put("Blues/Slow/Take 10.wav"); try put("Blues/Slow/Take 2.wav")
        try put("Rock/Backing.FLAC"); try put("notes.txt")
        let result = try AudioLibrary.scan(folder)
        XCTAssertEqual(result.trackCount, 4)
        XCTAssertEqual(result.groups.map(\.directory), ["", "Blues/Slow", "Rock"])
        XCTAssertEqual(result.groups[0].title, folder.lastPathComponent)
        XCTAssertEqual(result.groups[1].tracks.map(\.fileName), ["Take 2.wav", "Take 10.wav"])
        XCTAssertEqual(result.unreadableFolders, 0)
    }
    func testHiddenFilesDirectoriesPackagesAndSymlinksAreNotTraversed() throws {
        let original = try put("Original.wav")
        try put(".hidden.wav"); try put(".cache/Hidden.mp3"); try put("Session.app/Inside.wav")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Alias.wav"), withDestinationURL: original)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Cycle"), withDestinationURL: folder)
        let result = try AudioLibrary.scan(folder)
        XCTAssertEqual(result.groups.flatMap(\.tracks).map(\.fileName), ["Original.wav"])
    }
    func testDirectoryWithAudioExtensionIsNotAnAudioFile() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Folder.wav"), withIntermediateDirectories: true)
        XCTAssertEqual(try AudioLibrary.scan(folder).trackCount, 0)
    }
    func testEmptyFolderAndNonFolderAndMissingFolder() throws {
        XCTAssertTrue(try AudioLibrary.scan(folder).groups.isEmpty)
        let file = try put("A.wav")
        XCTAssertThrowsError(try AudioLibrary.scan(file))
        XCTAssertThrowsError(try AudioLibrary.scan(folder.appendingPathComponent("missing")))
    }
    func testSearchMatchesFilenamesAndSubfoldersAndDropsEmptyGroups() throws {
        try put("Jazz/Slow Ballad.wav"); try put("Rock/Fast.mp3")
        let groups = try AudioLibrary.scan(folder).groups
        XCTAssertEqual(AudioLibrary.filter(groups, query: "BALLAD").flatMap(\.tracks).map(\.fileName), ["Slow Ballad.wav"])
        XCTAssertEqual(AudioLibrary.filter(groups, query: " rock ").map(\.title), ["Rock"])
        XCTAssertEqual(AudioLibrary.filter(groups, query: "  "), groups)
        XCTAssertTrue(AudioLibrary.filter(groups, query: "missing").isEmpty)
    }
    func testCancellationStopsScan() async throws {
        try put("A.wav")
        let root = folder!
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AudioLibrary.scan(root)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
