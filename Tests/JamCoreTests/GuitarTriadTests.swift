import XCTest
@testable import JamCore

final class GuitarTriadTests: XCTestCase {
    func testEveryRootQualityStringSetAndInversionContainsOnlyTheCorrectNotes() throws {
        let roots = ["C", "C#", "Db", "D", "D#", "Eb", "E", "F", "F#", "Gb", "G", "G#", "Ab", "A", "A#", "Bb", "B"]
        var ids = Set<String>()
        for root in roots {
            let rootPitch = try XCTUnwrap(ChordTransposition.pitch(root))
            for quality in GuitarTriadQuality.allCases {
                let pitches = Set(quality.intervals.map { (rootPitch + $0) % 12 })
                for strings in GuitarTriadStringSet.allCases {
                    for inversion in GuitarTriadInversion.allCases {
                        let shapes = GuitarTriad.voicings(root: root, quality: quality, stringSet: strings, inversion: inversion)
                        XCTAssertFalse(shapes.isEmpty, "\(root) \(quality) \(strings) \(inversion)")
                        for triad in shapes {
                            XCTAssertTrue(ids.insert(triad.id).inserted)
                            XCTAssertTrue(triad.shape.isValid)
                            let played = triad.absoluteFrets.indices.filter { triad.absoluteFrets[$0] >= 0 }
                            XCTAssertEqual(played, Array(strings.firstString...(strings.firstString + 2)))
                            let notes = played.map { GuitarTriad.tuning[$0] + triad.absoluteFrets[$0] }
                            XCTAssertEqual(Set(notes.map { $0 % 12 }), pitches)
                            XCTAssertTrue(notes[0] < notes[1] && notes[1] < notes[2])
                            XCTAssertLessThan(notes[2] - notes[0], 12)
                            XCTAssertEqual(notes[0] % 12, (rootPitch + quality.intervals[inversion.rawValue]) % 12)
                            XCTAssertEqual(triad.rootStrings.count, 1)
                            let rootString = try XCTUnwrap(triad.rootStrings.first)
                            XCTAssertEqual((GuitarTriad.tuning[rootString] + triad.absoluteFrets[rootString]) % 12, rootPitch)
                            XCTAssertEqual(triad.degrees.filter { !$0.isEmpty }.count, 3)
                            for string in played {
                                let absolute = triad.absoluteFrets[string]
                                XCTAssertTrue((0...22).contains(absolute))
                                XCTAssertEqual(triad.shape.frets[string] == 0 ? 0 : triad.shape.frets[string] + triad.shape.baseFret - 1, absolute)
                            }
                        }
                    }
                }
            }
        }
    }

    func testFamiliarCMajorShapesIncludeAllThreeInversionsAndOpenStrings() {
        let root = GuitarTriad.voicings(root: "C", quality: .major, stringSet: .gbe, inversion: .root)
        let first = GuitarTriad.voicings(root: "C", quality: .major, stringSet: .gbe, inversion: .first)
        let second = GuitarTriad.voicings(root: "C", quality: .major, stringSet: .gbe, inversion: .second)
        XCTAssertTrue(root.contains { $0.absoluteFrets == [-1, -1, -1, 5, 5, 3] && $0.notes == ["C", "E", "G"] })
        XCTAssertTrue(first.contains { $0.absoluteFrets == [-1, -1, -1, 9, 8, 8] && $0.notes == ["E", "G", "C"] })
        XCTAssertTrue(second.contains { $0.absoluteFrets == [-1, -1, -1, 0, 1, 0] && $0.notes == ["G", "C", "E"] })
    }

    func testGToEmExampleKeepsTwoNotesAndChangesOnlyTheBString() throws {
        let g = try XCTUnwrap(GuitarTriad.voicings(root: "G", quality: .major, stringSet: .dgb, inversion: .root)
            .first { $0.absoluteFrets == [-1, -1, 5, 4, 3, -1] })
        let em = try XCTUnwrap(GuitarTriad.voicings(root: "E", quality: .minor, stringSet: .dgb, inversion: .first)
            .first { $0.absoluteFrets == [-1, -1, 5, 4, 5, -1] })
        XCTAssertEqual(g.notes, ["G", "B", "D"])
        XCTAssertEqual(em.notes, ["G", "B", "E"])
        XCTAssertEqual(g.rootStrings, [2])
        XCTAssertEqual(em.rootStrings, [4])
    }

    func testNoteSpellingPreservesDiatonicThirdsAndFifths() {
        XCTAssertEqual(GuitarTriad.noteNames(root: "C#", quality: .major), ["C♯", "E♯", "G♯"])
        XCTAssertEqual(GuitarTriad.noteNames(root: "Bb", quality: .diminished), ["B♭", "D♭", "F♭"])
        XCTAssertEqual(GuitarTriad.noteNames(root: "C", quality: .augmented), ["C", "E", "G♯"])
        XCTAssertTrue(GuitarTriad.voicings(root: "H", quality: .major, stringSet: .gbe, inversion: .root).isEmpty)
    }
}
