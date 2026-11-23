import Foundation

/// Strings run from low E to high E. Positive frets are relative to baseFret.
public struct GuitarChordShape: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let frets: [Int]
    public let fingers: [Int]
    public let baseFret: Int
    public let barres: [Int]
    public var id: String { "\(baseFret):\(frets):\(fingers):\(barres)" }
    public var isValid: Bool {
        frets.count == 6 && fingers.count == 6 && (1...24).contains(baseFret) &&
        frets.allSatisfy { (-1...24).contains($0) } && fingers.allSatisfy { (0...4).contains($0) } &&
        barres.allSatisfy { (1...24).contains($0) }
    }
    public var json: JSONValue {
        .object(["frets": .array(frets.map { .number(Double($0)) }),
                 "fingers": .array(fingers.map { .number(Double($0)) }),
                 "baseFret": .number(Double(baseFret)), "barres": .array(barres.map { .number(Double($0)) })])
    }
    init(frets: [Int], fingers: [Int], baseFret: Int, barres: [Int]) {
        self.frets = frets; self.fingers = fingers; self.baseFret = baseFret; self.barres = barres
    }
    public init?(json: JSONValue) {
        let fields = json.object
        frets = fields["frets"]?.array.compactMap { $0.text.flatMap(Int.init) } ?? []
        fingers = fields["fingers"]?.array.compactMap { $0.text.flatMap(Int.init) } ?? []
        baseFret = fields["baseFret"]?.text.flatMap(Int.init) ?? 1
        barres = fields["barres"]?.array.compactMap { $0.text.flatMap(Int.init) } ?? []
        guard isValid else { return nil }
    }
}

/// Offline MIT-licensed chords-db, pinned to df06fa7b425cf5fd29485ff6591236b3557e3fac.
/// Its license ships beside the data in the JamCore resource bundle.
public struct GuitarChordCatalogue: Sendable {
    public struct Group: Identifiable, Sendable {
        public let name: String
        public let root: String
        public let quality: String
        public let bass: String?
        public let shapes: [GuitarChordShape]
        public var id: String { name }
    }
    private struct Database: Decodable {
        struct Entry: Decodable { let key: String; let suffix: String; let positions: [GuitarChordShape] }
        let chords: [String: [Entry]]
    }
    public static let shared = GuitarChordCatalogue()
    private let entries: [String: [GuitarChordShape]]
    public let groups: [Group]
    public let positionCount: Int
    public init() {
        let database = Bundle.module.url(forResource: "GuitarChords", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Database.self, from: $0) }
        var entries: [String: [GuitarChordShape]] = [:]
        for entry in database?.chords.values.flatMap({ $0 }) ?? [] {
            guard let key = Self.key(entry.key + (entry.suffix == "major" ? "" : entry.suffix)) else { continue }
            var seen = Set<GuitarChordShape>()
            entries[key] = entry.positions.filter { $0.isValid && seen.insert($0).inserted }
        }
        self.entries = entries
        groups = entries.keys.sorted().compactMap { name in
            guard let shapes = entries[name], !shapes.isEmpty else { return nil }
            let chars = Array(name)
            let length = chars.count > 1 && ["#", "b"].contains(chars[1]) ? 2 : 1
            let suffix = String(chars.dropFirst(length)).split(separator: "/", omittingEmptySubsequences: false)
            let quality = suffix.first.map(String.init) ?? ""
            return Group(name: name, root: String(chars.prefix(length)),
                         quality: quality.isEmpty ? "major" : quality == "m" ? "minor" : quality,
                         bass: suffix.count > 1 ? String(suffix[1]) : nil, shapes: shapes)
        }
        positionCount = entries.values.reduce(0) { $0 + $1.count }
    }
    public func shapes(for chord: String) -> [GuitarChordShape] {
        guard let key = Self.key(chord) else { return [] }
        return entries[key] ?? []
    }
    public var qualities: [String] {
        let first = ["major", "minor", "sus2", "sus4", "5", "maj7", "7", "7sus4", "6", "add9"]
        let rest = Set(groups.map(\.quality)).subtracting(first).sorted()
        return first.filter { name in groups.contains { $0.quality == name } } + rest
    }
    public func filtered(root: String?, quality: String?, bass: String?, includeSlashChords: Bool = true) -> [Group] {
        groups.filter { group in
            (includeSlashChords || group.bass == nil) &&
            (root == nil || ChordTransposition.pitch(group.root) == root.flatMap(ChordTransposition.pitch)) &&
            (quality == nil || group.quality == quality) &&
            (bass == nil || group.bass.flatMap(ChordTransposition.pitch) == bass.flatMap(ChordTransposition.pitch))
        }
    }
    private static let rootNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private static func root(_ text: String) -> String? {
        guard let pitch = ChordTransposition.pitch(text) else { return nil }
        return rootNames[pitch]
    }
    public static func key(_ chord: String) -> String? {
        let name = chord.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        guard let first = name.first, "ABCDEFG".contains(first) else { return nil }
        let chars = Array(name)
        let rootLength = chars.count > 1 && ["#", "b"].contains(chars[1]) ? 2 : 1
        guard let root = root(String(chars.prefix(rootLength))) else { return nil }
        var suffix = String(chars.dropFirst(rootLength)).replacingOccurrences(of: "6/9", with: "69")
        let aliases = ["major": "", "maj": "", "M": "", "minor": "m", "min": "m", "-": "m",
                       "Δ": "maj7", "Δ7": "maj7", "M7": "maj7", "M9": "maj9", "M13": "maj13",
                       "min7": "m7", "min9": "m9", "min11": "m11", "min13": "m13",
                       "°": "dim", "°7": "dim7", "ø": "m7b5", "ø7": "m7b5", "+": "aug", "mMaj7": "mmaj7"]
        if let slash = suffix.lastIndex(of: "/") {
            let bass = String(suffix[suffix.index(after: slash)...])
            guard let bassRoot = Self.root(bass) else { return nil }
            let quality = String(suffix[..<slash])
            suffix = (aliases[quality] ?? quality) + "/" + bassRoot
        } else { suffix = aliases[suffix] ?? suffix }
        return root + suffix
    }
}

public extension ChordProDocument {
    /// Unique musical chords in first-appearance order, using the displayed key.
    /// The parser has already excluded literal tab, escaped brackets and comments.
    var guitarChords: [String] {
        var seen = Set<String>()
        return lines.flatMap(\.fragments).filter { !$0.isAnnotation }.map(\.chord).filter {
            guard GuitarChordCatalogue.key($0) != nil else { return false }
            return seen.insert($0).inserted
        }
    }
}

public extension LibrarySong {
    var chordVoicings: [String: GuitarChordShape] {
        (fields["macJamsChordVoicings"]?.object ?? [:]).compactMapValues(GuitarChordShape.init(json:))
    }
}
