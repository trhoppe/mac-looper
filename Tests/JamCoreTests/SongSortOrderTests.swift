import XCTest
@testable import JamCore

final class SongSortOrderTests: XCTestCase {
    private func song(_ id: String, _ title: String, _ artist: String) -> LibrarySong {
        LibrarySong(fields: ["id": .string(id), "title": .string(title), "artist": .string(artist), "rawData": .string("[C]Test")])
    }
    func testTitleSortUsesNaturalNumbersAndStableIDTieBreak() {
        let songs = [song("z", "Take 10", "A"), song("b", "Take 2", "Z"), song("a", "Take 2", "B")]
        XCTAssertEqual(SongSortOrder.songName.apply(to: songs, query: "").map(\.id), ["a", "b", "z"])
    }
    func testArtistSortGroupsArtistThenTitleWithMissingArtistsLast() {
        let songs = [song("a", "Zebra", "band"), song("b", "Alpha", "Band"), song("c", "First", ""), song("d", "Last", "Another")]
        XCTAssertEqual(SongSortOrder.artistName.apply(to: songs, query: "").map(\.id), ["d", "b", "a", "c"])
    }
    func testSearchMatchesTitleAndArtistUnderBothSortOrders() {
        let songs = [song("a", "Green Song", "Zebra"), song("b", "Another", "Green Day"), song("c", "Hidden", "Other")]
        XCTAssertEqual(SongSortOrder.songName.apply(to: songs, query: " green ").map(\.id), ["b", "a"])
        XCTAssertEqual(SongSortOrder.artistName.apply(to: songs, query: "GREEN").map(\.id), ["b", "a"])
    }
    func testPlaylistFilteringAndSongSettingsSurviveSorting() throws {
        let data = Data(#"{"songs":[{"id":"a","title":"Zebra","artist":"Band","rawData":"[C]A"},{"id":"b","title":"Alpha","rawData":"[G]B"},{"id":"c","title":"Outside","rawData":"C"}],"playlists":[{"id":"p","separateSongSettings":true,"arrangement":[{"type":"song","id":"a","capo":2},{"type":"song","id":"b"}]}]}"#.utf8)
        let library = try JustChordsLibrary(data: data)
        let sorted = SongSortOrder.songName.apply(to: library.songs(in: "p"), query: "")
        XCTAssertEqual(sorted.map(\.id), ["b", "a"])
        XCTAssertEqual(sorted.last?.capo, "2")
        XCTAssertEqual(library.originalData, data)
    }
}
