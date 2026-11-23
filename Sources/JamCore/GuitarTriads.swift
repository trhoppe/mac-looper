import Foundation

public enum GuitarTriadQuality: String, CaseIterable, Sendable {
    case major, minor, diminished, augmented
    public var title: String { rawValue.capitalized }
    public var suffix: String {
        switch self { case .major: return ""; case .minor: return "m"; case .diminished: return "dim"; case .augmented: return "aug" }
    }
    public var intervals: [Int] {
        switch self { case .major: return [0, 4, 7]; case .minor: return [0, 3, 7]; case .diminished: return [0, 3, 6]; case .augmented: return [0, 4, 8] }
    }
    public var degrees: [String] {
        switch self { case .major: return ["R", "3", "5"]; case .minor: return ["R", "♭3", "5"]; case .diminished: return ["R", "♭3", "♭5"]; case .augmented: return ["R", "3", "♯5"] }
    }
}

/// Adjacent strings, ordered from their lowest-pitched string to highest.
public enum GuitarTriadStringSet: String, CaseIterable, Sendable {
    case gbe, dgb, adg, ead
    public var title: String {
        switch self { case .gbe: return "G–B–E (3–2–1)"; case .dgb: return "D–G–B (4–3–2)"; case .adg: return "A–D–G (5–4–3)"; case .ead: return "E–A–D (6–5–4)" }
    }
    public var firstString: Int {
        switch self { case .gbe: return 3; case .dgb: return 2; case .adg: return 1; case .ead: return 0 }
    }
}

public enum GuitarTriadInversion: Int, CaseIterable, Sendable {
    case root, first, second
    public var title: String {
        switch self { case .root: return "Root position"; case .first: return "1st inversion"; case .second: return "2nd inversion" }
    }
}

/// A close-position triad in standard E–A–D–G–B–E tuning.
/// Generated from pitches rather than copied chord images or fingerings.
public struct GuitarTriad: Identifiable, Sendable {
    public let root: String
    public let quality: GuitarTriadQuality
    public let stringSet: GuitarTriadStringSet
    public let inversion: GuitarTriadInversion
    public let absoluteFrets: [Int]
    public let shape: GuitarChordShape
    public let degrees: [String]
    public let rootStrings: Set<Int>
    public let notes: [String]
    public var chordName: String { root + quality.suffix }
    public var id: String { "\(root):\(quality.rawValue):\(stringSet.rawValue):\(inversion.rawValue):\(absoluteFrets)" }
    public static let tuning = [40, 45, 50, 55, 59, 64]

    /// Every playable octave placement through fret 22, with exactly one of
    /// each chord tone. Close position means all three notes fit within an octave.
    public static func voicings(root: String, quality: GuitarTriadQuality,
                                stringSet: GuitarTriadStringSet, inversion: GuitarTriadInversion) -> [Self] {
        guard let pitch = ChordTransposition.pitch(root) else { return [] }
        let intervals = quality.intervals, bassDegree = inversion.rawValue
        let toneIndices = (0..<3).map { (bassDegree + $0) % 3 }
        let strings = Array(stringSet.firstString...(stringSet.firstString + 2))
        let spellings = noteNames(root: root, quality: quality)
        return (0...22).compactMap { (bassFret: Int) -> Self? in
            let bass = tuning[strings[0]] + bassFret
            guard bass % 12 == (pitch + intervals[bassDegree]) % 12 else { return nil }
            let frets = toneIndices.enumerated().map { offset, degree in
                bass + (intervals[degree] - intervals[bassDegree] + 12) % 12 - tuning[strings[offset]]
            }
            guard frets.allSatisfy({ (0...22).contains($0) }) else { return nil }
            let stopped = frets.filter { $0 > 0 }
            guard (stopped.max() ?? 0) - (stopped.min() ?? 0) <= 4 else { return nil }
            let base = (frets.max() ?? 0) <= 4 ? 1 : (stopped.min() ?? 1)
            var absolute = Array(repeating: -1, count: 6)
            var relative = absolute, degrees = Array(repeating: "", count: 6)
            var rootStrings = Set<Int>()
            for (offset, string) in strings.enumerated() {
                let degree = toneIndices[offset], fret = frets[offset]
                absolute[string] = fret
                relative[string] = fret == 0 ? 0 : fret - base + 1
                degrees[string] = quality.degrees[degree]
                if degree == 0 { rootStrings.insert(string) }
            }
            let shape = GuitarChordShape(frets: relative, fingers: Array(repeating: 0, count: 6), baseFret: base, barres: [])
            return Self(root: root, quality: quality, stringSet: stringSet, inversion: inversion,
                        absoluteFrets: absolute, shape: shape, degrees: degrees, rootStrings: rootStrings,
                        notes: toneIndices.map { spellings[$0] })
        }
    }

    /// Spell thirds and fifths diatonically (C# major has E#, Bb diminished has Fb).
    public static func noteNames(root: String, quality: GuitarTriadQuality) -> [String] {
        let letters = Array("CDEFGAB"), naturals = [0, 2, 4, 5, 7, 9, 11]
        guard let first = root.first, let index = letters.firstIndex(of: first), let pitch = ChordTransposition.pitch(root) else { return [] }
        return quality.intervals.enumerated().map { degree, interval in
            let letter = (index + degree * 2) % 7
            let difference = ((pitch + interval - naturals[letter]) % 12 + 18) % 12 - 6
            let accidental = difference > 0 ? String(repeating: "♯", count: difference) : String(repeating: "♭", count: -difference)
            return String(letters[letter]) + accidental
        }
    }
}
