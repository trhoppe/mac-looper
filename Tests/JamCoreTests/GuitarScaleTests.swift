import XCTest
@testable import JamCore

final class GuitarScaleTests: XCTestCase {
    func testAllLearningStylesStayInKeyAndWithinTheDisplayedNeck() throws {
        for root in ["C", "C#", "Db", "D", "D#", "Eb", "E", "F", "F#", "Gb", "G", "G#", "Ab", "A", "A#", "Bb", "B"] {
            for kind in GuitarPentatonic.allCases {
                let pitch = try XCTUnwrap(ChordTransposition.pitch(root))
                let full = Set(GuitarScales.neck(root: root, kind: kind).tones.map(\.id))
                for style in GuitarScaleLearningStyle.allCases {
                    let studies = GuitarScales.studies(root: root, kind: kind, style: style)
                    XCTAssertEqual(studies.count, style == .diagonal ? 2 : 1)
                    for study in studies {
                        XCTAssertEqual(study.pattern.firstFret, 0)
                        XCTAssertEqual(study.pattern.lastFret, 17)
                        XCTAssertFalse(study.pattern.tones.isEmpty)
                        XCTAssertTrue(study.pattern.tones.contains(where: \.isRoot))
                        let ids = Set(study.pattern.tones.map(\.id))
                        XCTAssertEqual(ids.count, study.pattern.tones.count)
                        XCTAssertTrue(ids.isSubset(of: full))
                        XCTAssertTrue(study.pattern.extensionIDs.isSubset(of: ids))
                        for tone in study.pattern.tones {
                            let interval = (GuitarScales.tuning[tone.string] + tone.fret - pitch + 12) % 12
                            let degree = try XCTUnwrap(kind.intervals.firstIndex(of: interval))
                            XCTAssertEqual(tone.degree, kind.degrees[degree])
                            XCTAssertEqual(tone.note, kind.noteNames(root: root)[degree])
                        }
                        if style == .essential { XCTAssertTrue(study.regions.allSatisfy { [1, 4].contains($0.position) }) }
                        if style == .diagonal {
                            XCTAssertGreaterThanOrEqual(study.path.count, 10)
                            let pitches = study.path.map { GuitarScales.tuning[$0.string] + $0.fret }
                            for (offset, pair) in zip(pitches, pitches.dropFirst()).enumerated() {
                                let (a, b) = pair
                                XCTAssertGreaterThan(b, a)
                                let index = try XCTUnwrap(kind.intervals.firstIndex(of: (a - pitch + 12) % 12))
                                let expected = (kind.intervals[(index + 1) % 5] - kind.intervals[index] + 12) % 12
                                if b - a != expected {
                                    // Clipping at open/17 may remove a tone on
                                    // one string before a later string re-enters.
                                    let frets = [study.path[offset].fret, study.path[offset + 1].fret]
                                    XCTAssertTrue(frets.min()! <= 1 || frets.max()! >= 16)
                                }
                            }
                            for string in 0..<6 {
                                let frets = study.path.filter { $0.string == string }.map(\.fret)
                                for (a, b) in zip(frets, frets.dropFirst()) { XCTAssertEqual(b - a, 2) }
                            }
                        }
                    }
                }
            }
        }
    }

    func testEssentialUsesBoxesOneAndFourWithTheCorrectConnectingNotes() throws {
        let study = try XCTUnwrap(GuitarScales.studies(root: "A", kind: .minor, style: .essential).first)
        XCTAssertEqual(study.pattern.extensionIDs, Set(["0:10", "1:10", "2:10", "3:9", "4:10", "5:10"]))
        XCTAssertTrue(study.pattern.tones.contains { $0.id == "4:10" && $0.isRoot })
        // Position 4 (low E frets 12/15), not the neighboring position 2.
        XCTAssertTrue(study.pattern.tones.contains { $0.id == "0:12" })
        XCTAssertTrue(study.pattern.tones.contains { $0.id == "0:15" })
        XCTAssertFalse(study.pattern.extensionIDs.contains("0:8"))
    }

    func testMajorThreeTwoAndMinorTwoThreeMatchFamiliarRoutes() {
        let major = GuitarScales.diagonal(root: "G", kind: .major, startingString: 0)
        XCTAssertEqual((0..<6).map { string in major.filter { $0.string == string }.map(\.fret) },
                       [[3, 5, 7], [5, 7], [5, 7, 9], [7, 9], [8, 10, 12], [10, 12]])
        let minor = GuitarScales.diagonal(root: "A", kind: .minor, startingString: 0)
        XCTAssertEqual((0..<6).map { string in minor.filter { $0.string == string }.map(\.fret) },
                       [[3, 5], [3, 5, 7], [5, 7], [5, 7, 9], [8, 10], [8, 10, 12]])
        let aStart = GuitarScales.diagonal(root: "A", kind: .minor, startingString: 1)
        XCTAssertEqual((0..<6).map { string in aStart.filter { $0.string == string }.map(\.fret) },
                       [[], [10, 12], [10, 12, 14], [12, 14], [13, 15, 17], [15, 17]])
        XCTAssertTrue(GuitarScales.diagonal(root: "H", kind: .minor, startingString: 0).isEmpty)
        XCTAssertTrue(GuitarScales.diagonal(root: "A", kind: .major, startingString: 2).isEmpty)
    }

    func testEveryBoxContainsTwoCorrectNotesPerStringAndAllFiveScaleTones() throws {
        let roots = ["C", "C#", "Db", "D", "D#", "Eb", "E", "F", "F#", "Gb", "G", "G#", "Ab", "A", "A#", "Bb", "B"]
        for root in roots {
            for kind in GuitarPentatonic.allCases {
                let pitch = try XCTUnwrap(ChordTransposition.pitch(root))
                for position in 1...5 {
                    let box = try XCTUnwrap(GuitarScales.box(root: root, kind: kind, position: position))
                    XCTAssertEqual(box.tones.count, 12, "\(root) \(kind) position \(position)")
                    XCTAssertEqual(Set(box.tones.map(\.degree)), Set(kind.degrees))
                    XCTAssertEqual(Set(box.tones.map(\.id)).count, 12)
                    for string in 0..<6 { XCTAssertEqual(box.tones.filter { $0.string == string }.count, 2) }
                    for tone in box.tones {
                        XCTAssertTrue((0...22).contains(tone.fret))
                        let interval = (GuitarScales.tuning[tone.string] + tone.fret - pitch + 12) % 12
                        let degree = try XCTUnwrap(kind.intervals.firstIndex(of: interval))
                        XCTAssertEqual(tone.degree, kind.degrees[degree])
                        XCTAssertEqual(tone.note, kind.noteNames(root: root)[degree])
                    }
                }
                let connected = try XCTUnwrap(GuitarScales.box(root: root, kind: kind, position: 1, connected: true))
                XCTAssertEqual(connected.tones.count, 18)
                XCTAssertEqual(connected.extensionIDs.count, 6)
                XCTAssertTrue(connected.tones.allSatisfy { (0...22).contains($0.fret) })
                XCTAssertEqual(Set(connected.tones.map(\.id)).count, connected.tones.count)
                for tone in connected.tones {
                    let interval = (GuitarScales.tuning[tone.string] + tone.fret - pitch + 12) % 12
                    XCTAssertTrue(kind.intervals.contains(interval))
                }
            }
        }
    }

    func testFamiliarAMinorBoxAndConnection() throws {
        let box = try XCTUnwrap(GuitarScales.box(root: "A", kind: .minor, position: 1))
        XCTAssertEqual((0..<6).map { string in box.tones.filter { $0.string == string }.map(\.fret) },
                       [[5, 8], [5, 7], [5, 7], [5, 7], [5, 8], [5, 8]])
        let connected = try XCTUnwrap(GuitarScales.box(root: "A", kind: .minor, position: 1, connected: true))
        XCTAssertEqual(connected.firstFret, 5)
        XCTAssertEqual(connected.lastFret, 10)
        XCTAssertEqual(connected.extensionIDs, Set(["0:10", "1:10", "2:10", "3:9", "4:10", "5:10"]))
    }

    func testFullNeckIsCompleteAndRelativeScalesShareLocations() {
        let aMinor = GuitarScales.neck(root: "A", kind: .minor)
        let cMajor = GuitarScales.neck(root: "C", kind: .major)
        XCTAssertEqual(Set(aMinor.tones.map(\.id)), Set(cMajor.tones.map(\.id)))
        XCTAssertEqual(aMinor.firstFret, 0)
        XCTAssertEqual(aMinor.lastFret, 17)
        XCTAssertTrue(aMinor.tones.allSatisfy { (0...17).contains($0.fret) })
        for string in 0..<6 {
            for fret in 0...17 {
                let expected = [0, 3, 5, 7, 10].contains((GuitarScales.tuning[string] + fret - 9 + 12) % 12)
                XCTAssertEqual(aMinor.tones.contains { $0.string == string && $0.fret == fret }, expected)
            }
        }
        XCTAssertNotEqual(aMinor.tones.filter(\.isRoot).map(\.id), cMajor.tones.filter(\.isRoot).map(\.id))
    }

    func testPositionLabelsFollowTheKeyAndRepeatAtTheOctave() {
        for root in ["C", "C#", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"] {
            for kind in GuitarPentatonic.allCases {
                let regions = GuitarScales.positionRegions(root: root, kind: kind)
                XCTAssertEqual(Set(regions.map(\.position)), Set(1...5))
                XCTAssertEqual(regions.map(\.firstFret), regions.map(\.firstFret).sorted())
                XCTAssertEqual(Set(regions.map(\.id)).count, regions.count)
                XCTAssertTrue(regions.allSatisfy { $0.firstFret >= 0 && $0.lastFret <= 17 && $0.firstFret < $0.lastFret })
            }
        }
        let a = GuitarScales.positionRegions(root: "A", kind: .minor)
        XCTAssertEqual(a.filter { $0.position == 1 }.map(\.firstFret), [5])
        XCTAssertEqual(a.filter { $0.position == 4 }.map(\.firstFret), [0, 12])
        XCTAssertEqual(a.filter { $0.position == 5 }.map(\.firstFret), [2, 14])
        XCTAssertEqual(a.filter { $0.position == 1 }.map(\.lastFret), [8])
        let g = GuitarScales.positionRegions(root: "G", kind: .minor)
        XCTAssertEqual(g.filter { $0.position == 1 }.map(\.firstFret), [3, 15])
        XCTAssertTrue(GuitarScales.positionRegions(root: "H", kind: .minor).isEmpty)
    }

    func testNoteSpellingAndInvalidInputs() {
        XCTAssertEqual(GuitarPentatonic.minor.noteNames(root: "A"), ["A", "C", "D", "E", "G"])
        XCTAssertEqual(GuitarPentatonic.major.noteNames(root: "C#"), ["C♯", "D♯", "E♯", "G♯", "A♯"])
        XCTAssertEqual(GuitarPentatonic.minor.noteNames(root: "Bb"), ["B♭", "D♭", "E♭", "F", "A♭"])
        XCTAssertNil(GuitarScales.box(root: "H", kind: .minor, position: 1))
        XCTAssertNil(GuitarScales.box(root: "A", kind: .minor, position: 6))
        XCTAssertTrue(GuitarScales.neck(root: "H", kind: .major).tones.isEmpty)
    }
}
