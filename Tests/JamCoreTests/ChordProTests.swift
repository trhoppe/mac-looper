import XCTest
@testable import JamCore
final class ChordProTests: XCTestCase {
    func testDirectivesUnicodeAndMalformedChordsPreserveLyrics() {
        let d = ChordProDocument(source: "{title: Test}\n{soc}\n[C]Héllo [G/B]世界\n{eoc}\nBroken [unfinished\n{future: ignored}\n")
        XCTAssertEqual(d.metadata["title"], "Test")
        XCTAssertEqual(d.lines.first?.kind, .section)
        XCTAssertEqual(d.lines[1].fragments.map(\.lyric).joined(), "Héllo 世界")
        XCTAssertTrue(d.lines.contains { $0.fragments.map(\.lyric).joined() == "Broken [unfinished" })
        XCTAssertEqual(d.unsupportedDirectives, ["future"])
    }
    func testEscapesAndAdjacentChords() {
        let fragments = ChordProDocument.fragments("[Am][G/B]Hi \\[literal\\]")
        XCTAssertEqual(fragments.map(\.chord), ["Am", "G/B"])
        XCTAssertEqual(fragments.map(\.lyric).joined(), "Hi [literal]")
    }
    func testSavedTranspositionHandlesSlashChordsAndSuffixes() {
        XCTAssertEqual(ChordTransposition.transpose("Cmaj7/G", semitones: 2, flats: false), "Dmaj7/A")
        XCTAssertEqual(ChordTransposition.transpose("A5", semitones: -1, flats: true), "Ab5")
        XCTAssertEqual(ChordTransposition.transpose("N.C.", semitones: 2, flats: false), "N.C.")
        let d = ChordProDocument(source: "[C]Hi [G/B]there", transpose: 2)
        XCTAssertEqual(d.lines[0].fragments.map(\.chord), ["D", "A/C#"])
    }
    func testTabsPlainHeadingsAndWordLayoutDoNotLoseText() {
        let d = ChordProDocument(source: "Intro:\n{start_of_tab}\ne|---0---|\n{end_of_tab}\n[C]Hello world  ")
        XCTAssertEqual(d.lines[0].kind, .section); XCTAssertEqual(d.lines[1].kind, .tablature)
        let words = ChordProDocument.words(d.lines[2].fragments)
        XCTAssertEqual(words.map(\.lyric).joined(), "Hello world  ")
        XCTAssertEqual(words.first?.chord, "C")
    }
}
