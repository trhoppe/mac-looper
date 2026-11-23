import Foundation

public enum GuitarPentatonic: String, CaseIterable, Sendable {
    case minor, major

    public var title: String { rawValue.capitalized + " pentatonic" }
    public var intervals: [Int] { self == .minor ? [0, 3, 5, 7, 10] : [0, 2, 4, 7, 9] }
    public var degrees: [String] { self == .minor ? ["R", "♭3", "4", "5", "♭7"] : ["R", "2", "3", "5", "6"] }

    public func noteNames(root: String) -> [String] {
        let letters = Array("CDEFGAB"), naturals = [0, 2, 4, 5, 7, 9, 11]
        guard let first = root.first, let index = letters.firstIndex(of: first),
              let pitch = ChordTransposition.pitch(root) else { return [] }
        let steps = self == .minor ? [0, 2, 3, 4, 6] : [0, 1, 2, 4, 5]
        return intervals.enumerated().map { degree, interval in
            let letter = (index + steps[degree]) % 7
            let difference = ((pitch + interval - naturals[letter]) % 12 + 18) % 12 - 6
            let accidental = difference > 0 ? String(repeating: "♯", count: difference) : String(repeating: "♭", count: -difference)
            return String(letters[letter]) + accidental
        }
    }
}

public enum GuitarScaleLearningStyle: String, CaseIterable, Sendable {
    case full, essential, diagonal
    public var title: String {
        switch self { case .full: return "Full"; case .essential: return "Essential"; case .diagonal: return "3:2" }
    }
}

/// A scale tone at an absolute fret in standard E–A–D–G–B–E tuning.
public struct GuitarScaleTone: Identifiable, Equatable, Sendable {
    public let string: Int // 0 = low E, 5 = high E
    public let fret: Int
    public let degree: String
    public let note: String
    public var isRoot: Bool { degree == "R" }
    public var id: String { "\(string):\(fret)" }
}

public struct GuitarScalePattern: Sendable {
    public let tones: [GuitarScaleTone]
    public let firstFret: Int
    public let lastFret: Int
    /// Notes added by the second box in the connected view.
    public let extensionIDs: Set<String>
}

/// Overlapping box ranges on the displayed neck, including octave repeats.
public struct GuitarScalePositionRegion: Identifiable, Equatable, Sendable {
    public let position: Int
    public let firstFret: Int
    public let lastFret: Int
    public var id: String { "\(position):\(firstFret):\(lastFret)" }
}

public struct GuitarScaleStudy: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let pattern: GuitarScalePattern
    public let regions: [GuitarScalePositionRegion]
    /// Ascending scale tones for a diagonal route, before sorting for display.
    public let path: [GuitarScaleTone]
}

public enum GuitarScales {
    public static let tuning = [40, 45, 50, 55, 59, 64]
    public static let lastNeckFret = 17

    // Two notes per string; offsets from the minor root on low E.
    private static let minorBoxes = [
        [[0, 3], [0, 2], [0, 2], [0, 2], [0, 3], [0, 3]],
        [[3, 5], [2, 5], [2, 5], [2, 4], [3, 5], [3, 5]],
        [[5, 7], [5, 7], [5, 7], [4, 7], [5, 8], [5, 7]],
        [[7, 10], [7, 10], [7, 9], [7, 9], [8, 10], [7, 10]],
        [[10, 12], [10, 12], [9, 12], [9, 12], [10, 12], [10, 12]]
    ]

    private static func offsets(kind: GuitarPentatonic, position: Int) -> [[Int]] {
        if kind == .minor { return minorBoxes[position - 1] }
        // Major position 1 has the low-E root under the middle finger.
        // Its relative minor is three semitones lower. Numbering varies by method.
        let index = position % 5
        let shift = index == 0 ? 9 : -3
        return minorBoxes[index].map { $0.map { $0 + shift } }
    }

    public static func neck(root: String, kind: GuitarPentatonic) -> GuitarScalePattern {
        let tones = tones(root: root, kind: kind, locations: (0..<6).flatMap { string in
            (0...lastNeckFret).map { (string, $0) }
        })
        return GuitarScalePattern(tones: tones, firstFret: 0, lastFret: lastNeckFret, extensionIDs: [])
    }

    public static func positionRegions(root: String, kind: GuitarPentatonic) -> [GuitarScalePositionRegion] {
        guard let pitch = ChordTransposition.pitch(root) else { return [] }
        let anchor = (pitch - 4 + 12) % 12
        var result: [GuitarScalePositionRegion] = []
        for position in 1...5 {
            let frets = offsets(kind: kind, position: position).flatMap { $0 }
            for octave in -2...2 {
                let first = max(0, anchor + (frets.min() ?? 0) + octave * 12)
                let last = min(lastNeckFret, anchor + (frets.max() ?? 0) + octave * 12)
                // A single shared boundary fret cannot show a useful box range.
                if last > first {
                    result.append(GuitarScalePositionRegion(position: position, firstFret: first, lastFret: last))
                }
            }
        }
        return result.sorted { $0.firstFret < $1.firstFret }
    }

    public static func studies(root: String, kind: GuitarPentatonic, style: GuitarScaleLearningStyle) -> [GuitarScaleStudy] {
        switch style {
        case .full:
            return [GuitarScaleStudy(id: "full", title: "Full neck", pattern: neck(root: root, kind: kind),
                                     regions: positionRegions(root: root, kind: kind), path: [])]
        case .essential:
            return [GuitarScaleStudy(id: "essential", title: "Essential · Positions 1 & 4", pattern: essential(root: root, kind: kind),
                                     regions: positionRegions(root: root, kind: kind).filter { [1, 4].contains($0.position) }, path: [])]
        case .diagonal:
            return (0...1).map { start in
                let path = diagonal(root: root, kind: kind, startingString: start)
                let pattern = GuitarScalePattern(tones: path.sorted { $0.string == $1.string ? $0.fret < $1.fret : $0.string < $1.string },
                                                firstFret: 0, lastFret: lastNeckFret, extensionIDs: [])
                return GuitarScaleStudy(id: "diagonal-\(start)", title: "\(kind == .major ? "3:2" : "2:3") · \(start == 0 ? "Low E" : "A") start",
                                       pattern: pattern, regions: [], path: path)
            }
        }
    }

    /// Keep the two selected boxes and mark scale tones between their notes on
    /// each string. Octave repeats keep the same map as the Full view.
    private static func essential(root: String, kind: GuitarPentatonic) -> GuitarScalePattern {
        let full = neck(root: root, kind: kind)
        guard let pitch = ChordTransposition.pitch(root) else { return full }
        let anchor = (pitch - 4 + 12) % 12
        let first = offsets(kind: kind, position: 1), fourth = offsets(kind: kind, position: 4)
        var primary = Set<String>(), connectors = Set<String>()
        for octave in -2...2 {
            let base = anchor + octave * 12
            for string in 0..<6 {
                for fret in first[string] + fourth[string] { primary.insert("\(string):\(base + fret)") }
                let lower = base + (first[string].max() ?? 0), upper = base + (fourth[string].min() ?? 0)
                for tone in full.tones where tone.string == string && tone.fret > lower && tone.fret < upper {
                    connectors.insert(tone.id)
                }
            }
        }
        let selected = full.tones.filter { primary.contains($0.id) || connectors.contains($0.id) }
        return GuitarScalePattern(tones: selected, firstFret: 0, lastFret: lastNeckFret,
                                  extensionIDs: connectors.subtracting(primary))
    }

    /// Major uses R–2–3 / 5–6 (3:2); minor uses b7–R / b3–4–5 (2:3).
    /// Repeat the five scale tones in ascending pitch, automatically accounting
    /// for the B string's tuning. Choose the octave with the most visible notes.
    public static func diagonal(root: String, kind: GuitarPentatonic, startingString: Int) -> [GuitarScaleTone] {
        guard (0...1).contains(startingString), let pitch = ChordTransposition.pitch(root) else { return [] }
        let rootFret = (pitch - tuning[startingString] % 12 + 12) % 12
        let names = kind.noteNames(root: root)
        var candidates: [[GuitarScaleTone]] = []
        for octave in -1...1 {
            let anchor = tuning[startingString] + rootFret + octave * 12
            var degree = kind == .major ? 0 : 4
            var midi = anchor + (kind == .major ? 0 : -2)
            var route: [GuitarScaleTone] = []
            for string in startingString..<6 {
                let pairIndex = (string - startingString) % 2
                let count = kind == .major ? (pairIndex == 0 ? 3 : 2) : (pairIndex == 0 ? 2 : 3)
                for _ in 0..<count {
                    let fret = midi - tuning[string]
                    if (0...lastNeckFret).contains(fret) {
                        route.append(GuitarScaleTone(string: string, fret: fret, degree: kind.degrees[degree], note: names[degree]))
                    }
                    let next = (degree + 1) % 5
                    midi += (kind.intervals[next] - kind.intervals[degree] + 12) % 12
                    degree = next
                }
            }
            candidates.append(route)
        }
        return candidates.enumerated().max { lhs, rhs in
            // Prefer the lower octave when equally complete.
            lhs.element.count == rhs.element.count ? lhs.offset > rhs.offset : lhs.element.count < rhs.element.count
        }?.element ?? []
    }

    public static func box(root: String, kind: GuitarPentatonic, position: Int, connected: Bool = false) -> GuitarScalePattern? {
        guard (1...5).contains(position), let pitch = ChordTransposition.pitch(root) else { return nil }
        let first = offsets(kind: kind, position: position)
        // Connected practice view uses adjacent positions 1 and 2 at the same octave.
        let next = connected && position == 1 ? offsets(kind: kind, position: 2) : first
        let allOffsets = (first + next).flatMap { $0 }
        var anchor = (pitch - 4 + 12) % 12
        if anchor + (allOffsets.min() ?? 0) < 0 { anchor += 12 }
        if anchor + (allOffsets.max() ?? 0) > 22 { anchor -= 12 }
        guard anchor + (allOffsets.min() ?? 0) >= 0,
              anchor + (allOffsets.max() ?? 0) <= 22 else { return nil }
        let locations = first.enumerated().flatMap { string, frets in frets.map { (string, anchor + $0) } }
        let extra = next.enumerated().flatMap { string, frets in frets.map { (string, anchor + $0) } }
        let primary = tones(root: root, kind: kind, locations: locations)
        let combined = tones(root: root, kind: kind, locations: locations + extra)
        let ids = Set(primary.map(\.id))
        return GuitarScalePattern(tones: combined, firstFret: combined.map(\.fret).min() ?? 0,
                                  lastFret: combined.map(\.fret).max() ?? 0,
                                  extensionIDs: Set(combined.map(\.id)).subtracting(ids))
    }

    private static func tones(root: String, kind: GuitarPentatonic, locations: [(Int, Int)]) -> [GuitarScaleTone] {
        guard let pitch = ChordTransposition.pitch(root) else { return [] }
        let names = kind.noteNames(root: root)
        var seen = Set<String>()
        return locations.compactMap { string, fret in
            guard (0..<6).contains(string), (0...22).contains(fret),
                  let degree = kind.intervals.firstIndex(of: (tuning[string] + fret - pitch + 12) % 12) else { return nil }
            let tone = GuitarScaleTone(string: string, fret: fret, degree: kind.degrees[degree], note: names[degree])
            return seen.insert(tone.id).inserted ? tone : nil
        }.sorted { $0.string == $1.string ? $0.fret < $1.fret : $0.string < $1.string }
    }
}
