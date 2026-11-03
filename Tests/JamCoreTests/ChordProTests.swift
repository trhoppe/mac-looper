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

extension ChordProTests {
    func testUnmarkedTabRowsStayTogetherAndKeepTheirColumns() {
        let rows = ["e|----8-----|", "B|--6---9---|", "G|---------|", "D|---------|", "A|---------|", "E|---------|"]
        let document = ChordProDocument(source: "Solo:\n" + rows.joined(separator: "\n") + "\n\n[C]Words")
        let tabs = document.blocks.filter(\.isTablature)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].lines.map(\.text), rows)
        XCTAssertEqual(document.lines.filter { $0.kind == .tablature }.count, 6)
    }
    func testAdjacentVerseChordsReserveVisibleSpacesWithoutChangingLyrics() {
        let source = "Test words  [Ab5][Db5][Gb5][Db5][Ab5][B]"
        let fragments = ChordProDocument.fragments(source)
        let words = ChordProDocument.words(fragments)
        XCTAssertEqual(words.map(\.lyric).joined(), "Test words  ")
        let chordOnly = words.filter { !$0.chord.isEmpty && $0.lyric.isEmpty }
        XCTAssertEqual(chordOnly.count, 6)
        XCTAssertTrue(chordOnly.allSatisfy { $0.displayColumns > $0.chord.count })
    }
}

extension ChordProTests {
    func testDirectiveArgumentsAcceptColonWhitespaceAliasesAndRepeatedMetadata() {
        let document = ChordProDocument(source: """
        {t First song}
        {st: A subtitle}
        {artist One artist}
        {meta: artist Another artist}
        {meta composer Writer One}
        {composer: Writer Two}
        {duration 268}
        {tempo : 120}
        {time 6/8}
        {arranger: Arranger}
        {meta custom_name Custom value}
        """)
        XCTAssertEqual(document.metadata["title"], "First song")
        XCTAssertEqual(document.metadataValues["artist"], ["One artist", "Another artist"])
        XCTAssertEqual(document.metadataValues["composer"], ["Writer One", "Writer Two"])
        XCTAssertEqual(document.metadata["custom_name"], "Custom value")
        XCTAssertEqual(document.metadata["tempo"], "120")
        XCTAssertEqual(document.metadata["time"], "6/8")
        XCTAssertTrue(document.unsupportedDirectives.isEmpty)
        XCTAssertTrue(document.lines.isEmpty)
    }
    func testSectionLabelsAcceptQuotedAttributesAndLegacySyntax() {
        let document = ChordProDocument(source: #"""
        {sov label="Verse 1\nQuietly"}
        [C]Words
        {eov}
        {start_of_bridge: label='Bridge two'}
        [G]More
        {eob}
        {soc Last chorus}
        [D]End
        {eoc}
        """#)
        XCTAssertEqual(document.lines.filter { $0.kind == .section }.map(\.text), ["Verse 1\nQuietly", "Bridge two", "Last chorus"])
        XCTAssertTrue(document.unsupportedDirectives.isEmpty)
    }
    func testExplicitTabsAreLiteralIncludingCommentsDirectivesBlankLinesAndBrackets() {
        let body = ["# literal tab note", "{title: not metadata}", "", "e|--[0]--|", "{sot}"]
        let source = "{sot label='Solo'}\n" + body.joined(separator: "\n") + "\n{eot}\n[C]Words"
        let document = ChordProDocument(source: source)
        XCTAssertEqual(document.lines.first?.text, "Solo")
        XCTAssertNil(document.metadata["title"])
        XCTAssertEqual(document.blocks.filter(\.isTablature).count, 1)
        XCTAssertEqual(document.blocks.first(where: \.isTablature)?.lines.map(\.text), body)
        XCTAssertEqual(document.lines.last?.fragments.first?.chord, "C")
        let ns = source as NSString
        XCTAssertEqual(ChordProSyntax.spans(in: source).filter { $0.style == .directive }.map { ns.substring(with: $0.range) }, ["{sot label='Solo'}", "{eot}"])
        XCTAssertEqual(ChordProSyntax.spans(in: source).filter { $0.style == .chord }.map { ns.substring(with: $0.range) }, ["[C]"])
        XCTAssertTrue(document.warnings.isEmpty)
    }
    func testChorusRecallUsesLastCompletedDefinitionAndFreshLineIDs() {
        let document = ChordProDocument(source: "{soc: First}\n[C]One\n{eoc}\n{chorus}\n{soc: Second}\n[G]Two\n{ci: Soft}\n{eoc}\n{chorus: Final}", transpose: 2)
        XCTAssertEqual(document.lines.filter { $0.kind == .section }.map(\.text), ["First", "First", "Second", "Final"])
        XCTAssertEqual(document.lines.filter { $0.kind == .lyrics }.flatMap(\.fragments).map(\.chord), ["D", "D", "A", "A"])
        XCTAssertEqual(document.lines.filter { $0.kind == .comment }.map(\.commentStyle), [.italic, .italic])
        XCTAssertEqual(Set(document.lines.map(\.id)).count, document.lines.count)
        XCTAssertTrue(document.warnings.isEmpty)
    }
    func testAnnotationsAreNotTransposedAndArbitraryChordLabelsStillDisplay() {
        let document = ChordProDocument(source: "[*Coda]Hold [Cmaj7/G]this [IV]then [1m]that [N.C.]stop [Riff A]again", transpose: 2)
        let fragments = document.lines[0].fragments
        XCTAssertEqual(fragments.map(\.chord), ["Coda", "Dmaj7/A", "IV", "1m", "N.C.", "Riff A"])
        XCTAssertTrue(fragments[0].isAnnotation)
        let words = ChordProDocument.words(fragments)
        XCTAssertTrue(words[0].isAnnotation)
        XCTAssertEqual(words.map(\.lyric).joined(), "Hold this then that stop again")
        XCTAssertEqual(ChordProDocument.fragments("[*Fine]")[0].chord, "Fine")
    }
    func testCommentVariantsRetainTheirAppearance() {
        let document = ChordProDocument(source: "{c: Normal}\n{highlight Highlighted}\n{ci: Quietly}\n{cb: Repeat twice}")
        XCTAssertEqual(document.lines.map(\.commentStyle), [.plain, .plain, .italic, .box])
        XCTAssertEqual(document.lines.map(\.text), ["Normal", "Highlighted", "Quietly", "Repeat twice"])
        XCTAssertTrue(document.unsupportedDirectives.isEmpty)
    }
    func testUnknownDirectivesAreReportedButApplicationExtensionsAreIgnored() {
        let document = ChordProDocument(source: "{x_other_app: value}\n{future: value}\n{future: other}\n{chorus}\n{meta}\n{sot}\ne|---|")
        XCTAssertEqual(document.unsupportedDirectives, ["future"])
        XCTAssertEqual(document.warnings.count, 3)
        XCTAssertEqual(document.lines.last?.text, "e|---|")
    }
    func testDurationAcceptsSecondsAndReadableTimes() {
        XCTAssertEqual(ChordProDocument.readableDuration("268"), "4:28")
        XCTAssertEqual(ChordProDocument.readableDuration("0"), "0:00")
        XCTAssertEqual(ChordProDocument.readableDuration("4:28"), "4:28")
        XCTAssertEqual(ChordProDocument.readableDuration("1:04:28"), "1:04:28")
    }
    func testUnimplementedMarkupAndSubstitutionHaveVisibleDiagnostics() {
        let source = "<b>[C]Words</b>\n{comment: By %{artist}}\n<sot>"
        let document = ChordProDocument(source: source)
        XCTAssertEqual(document.warnings.count, 2)
        XCTAssertTrue(document.lines.contains { $0.text.contains("%{artist}") })
        let tab = ChordProDocument(source: "{sot}\n<b>literal</b> %{artist}\n{eot}")
        XCTAssertTrue(tab.warnings.isEmpty)
    }
    func testReadOnlyUserLibraryAuditWhenExplicitlyProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_JAMS_CHORDPRO_AUDIT_LIBRARY"] else {
            throw XCTSkip("Set MAC_JAMS_CHORDPRO_AUDIT_LIBRARY for the optional read-only library audit.")
        }
        let library = try JustChordsLibrary(data: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(library.songs.isEmpty)
        let converted = try library.migratingToChordPro()
        XCTAssertEqual(try converted.migratingToChordPro().originalData, converted.originalData)
        for (index, song) in library.songs.enumerated() {
            let migrated = converted.songs[index]
            XCTAssertNil(SongDraft(song: migrated).validationError, "A converted song must remain editable")
            XCTAssertEqual(migrated.id, song.id); XCTAssertEqual(migrated.title, song.title)
            XCTAssertEqual(migrated.artist, song.artist); XCTAssertEqual(migrated.tempo, song.tempo)
            XCTAssertEqual(migrated.timeSignature, song.timeSignature); XCTAssertEqual(migrated.duration, song.duration)
            XCTAssertEqual(migrated.displayKey, song.displayKey); XCTAssertEqual(migrated.transposition, song.transposition)
            let before = ChordProDocument(source: song.chordPro), after = ChordProDocument(source: migrated.chordPro)
            XCTAssertEqual(before.lines.flatMap(\.fragments), after.lines.flatMap(\.fragments), "Conversion changed musical content")
            XCTAssertEqual(before.lines.filter { $0.kind == .section }.map(\.text), after.lines.filter { $0.kind == .section }.map(\.text))
            XCTAssertEqual(before.lines.filter { $0.kind == .tablature && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.text), after.lines.filter { $0.kind == .tablature && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.text))
            XCTAssertTrue(after.warnings.isEmpty); XCTAssertTrue(after.unsupportedDirectives.isEmpty)
            let document = ChordProDocument(source: song.chordPro)
            XCTAssertTrue(document.unsupportedDirectives.isEmpty, "Library contains a directive requiring review")
            XCTAssertTrue(document.warnings.isEmpty, "Library contains a structure requiring review")
            XCTAssertEqual(Set(document.lines.map(\.id)).count, document.lines.count)
            // All actual library charts currently use ordinary bracket chords.
            // Compare their tokens without copying any private chart into the repo.
            let expected = song.chordPro.components(separatedBy: "\n").flatMap { ChordProDocument.fragments($0) }.map(\.chord).filter { !$0.isEmpty }
            let actual = document.lines.flatMap(\.fragments).map(\.chord).filter { !$0.isEmpty }
            XCTAssertEqual(actual, expected, "A library chord was lost while building the chart")
        }
    }
}

extension ChordProTests {
    func testQuotedLabelsDecodeBackslashesWithoutTurningLiteralSlashNIntoANewline() {
        let document = ChordProDocument(source: #"{sov label="A\\n \"quoted\" label"}"#)
        XCTAssertEqual(document.lines.first?.text, #"A\n "quoted" label"#)
    }
    func testLaterMusicalMetadataIsVisibleButDoesNotReplaceThePreamble() {
        let source = "{title: Test}\n{key: C}\n{tempo: 120}\n[C]First\n{meta: key D}\n{tempo 140}\n{time 6/8}\n[D]Next"
        let document = ChordProDocument(source: source)
        XCTAssertEqual(document.lines.filter { $0.kind == .comment }.map(\.text), ["Key D", "Tempo 140 BPM", "Time 6/8"])
        let preamble = ChordProSongSource(source)
        XCTAssertEqual(preamble.first("key"), "C"); XCTAssertEqual(preamble.first("tempo"), "120")
        XCTAssertTrue(preamble.body.contains("{meta: key D}"))
    }
}
