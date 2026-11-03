import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var text: String? {
        switch self { case .string(let v): return v; case .number(let v): return v.rounded() == v ? String(format: "%.0f", v) : String(v); default: return nil }
    }
    public var boolean: Bool { if case .bool(let v) = self { return v }; return false }
}

public struct LibrarySong: Identifiable, Equatable, Sendable {
    public let fields: [String: JSONValue]
    public let chordProMetadata: ChordProSongSource
    public var isChordProNative: Bool { fields["macJamsChordProVersion"] == .number(1) }
    private func metadata(_ name: String, legacy: String) -> String? {
        if let value = chordProMetadata.first(name) { return value.isEmpty ? nil : value }
        return isChordProNative ? nil : fields[legacy]?.text
    }
    public var id: String { fields["id"]?.text ?? "" }
    public var title: String { metadata("title", legacy: "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled" }
    public var artist: String {
        if let artists = chordProMetadata.values["artist"] { return artists.joined(separator: ", ") }
        return isChordProNative ? "" : fields["artist"]?.text ?? ""
    }
    public var chordPro: String { fields["rawData"]?.text ?? "" }
    public var tags: [String] { fields["tags"]?.array.compactMap(\.text) ?? [] }
    public var tempo: Double? { metadata("tempo", legacy: "tempo").flatMap(Double.init) }
    public var duration: String? { metadata("duration", legacy: "duration") }
    public var timeSignature: String? { metadata("time", legacy: "timeSignature") }
    public var capo: String? { metadata("capo", legacy: "capo") }
    var legacyKey: String? {
        fields["keyChord"]?.object["key"]?.text.map { $0 + (fields["keyChord"]?.object["minor"]?.boolean == true && !$0.hasSuffix("m") ? "m" : "") }
    }
    public var sourceKey: String? {
        if let key = chordProMetadata.first("key") { return key.isEmpty ? nil : key }
        return isChordProNative ? nil : legacyKey
    }
    public var originalKey: String? {
        sourceKey.map {
            let root = $0.hasSuffix("m") ? String($0.dropLast()) : $0
            return String(root.prefix(1)).uppercased() + root.dropFirst().replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        }
    }
    public var displayKey: String? {
        let root = fields["transpose"]?.text ?? originalKey
        return root.map { $0 + (sourceKey?.hasSuffix("m") == true && !$0.hasSuffix("m") ? "m" : "") }
    }
    public var transposition: Int {
        guard let base = originalKey, let target = fields["transpose"]?.text,
              let a = ChordTransposition.pitch(base), let b = ChordTransposition.pitch(target) else { return 0 }
        return b - a
    }
    public init(fields: [String: JSONValue]) {
        self.fields = fields; chordProMetadata = ChordProSongSource(fields["rawData"]?.text ?? "")
    }
    public func applying(_ entry: [String: JSONValue]) -> LibrarySong {
        var merged = fields
        for key in ["capo", "transpose", "tempo", "keyChord"] { if let v = entry[key], v != .null { merged[key] = v } }
        var source = ChordProSongSource(chordPro)
        for (field, directive) in [("capo", "capo"), ("tempo", "tempo")] {
            if let value = entry[field]?.text { source = ChordProSongSource(source.setting(directive, to: value)) }
        }
        if let value = entry["keyChord"], value != .null {
            let key = value.object
            if let root = key["key"]?.text { source = ChordProSongSource(source.setting("key", to: root + (key["minor"]?.boolean == true ? "m" : ""))) }
        }
        merged["rawData"] = .string(source.source)
        return LibrarySong(fields: merged)
    }
}

public struct LibraryPlaylist: Identifiable, Equatable, Sendable {
    public let fields: [String: JSONValue]
    public var id: String { fields["id"]?.text ?? "" }
    public var title: String { fields["title"]?.text ?? "Untitled playlist" }
    public var separateSongSettings: Bool { fields["separateSongSettings"]?.boolean ?? false }
    public var songEntries: [[String: JSONValue]] {
        func flatten(_ items: [JSONValue]) -> [[String: JSONValue]] {
            items.flatMap { item -> [[String: JSONValue]] in
                let v = item.object
                if v["type"]?.text == "song" { return [v] }
                return flatten(v["arrangement"]?.array ?? [])
            }
        }
        return flatten(fields["arrangement"]?.array ?? [])
    }
}

public struct LibraryTag: Identifiable, Equatable, Sendable {
    public let fields: [String: JSONValue]
    public var id: String { fields["id"]?.text ?? "" }
    public var name: String { fields["name"]?.text ?? "" }
    public var hidden: Bool { fields["hidden"]?.boolean ?? false }
}

public struct JustChordsLibrary: Sendable {
    // Viewing retains exact bytes. Explicit edits patch only the selected song's
    // changed fields, retaining unknown data, trash, IDs and playlist settings.
    public let originalData: Data
    public let root: [String: JSONValue]
    public let songs: [LibrarySong]
    public let playlists: [LibraryPlaylist]
    public let tags: [LibraryTag]
    public init(data: Data) throws {
        let root = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard case .array = root["songs"], case .array = root["playlists"] else { throw LibraryError.invalidFormat }
        let songs = (root["songs"]?.array ?? []).map { LibrarySong(fields: $0.object) }
        guard songs.allSatisfy({ !$0.id.isEmpty && $0.fields["rawData"]?.text != nil }), Set(songs.map(\.id)).count == songs.count else { throw LibraryError.invalidFormat }
        self.originalData = data; self.root = root; self.songs = songs
        self.playlists = (root["playlists"]?.array ?? []).map { LibraryPlaylist(fields: $0.object) }
        self.tags = (root["tags"]?.array ?? []).map { LibraryTag(fields: $0.object) }
    }
    public func songs(in playlistID: String?) -> [LibrarySong] {
        guard let id = playlistID, let playlist = playlists.first(where: { $0.id == id }) else {
            return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        return playlist.songEntries.compactMap { entry in
            guard let id = entry["id"]?.text, let song = byID[id] else { return nil }
            return playlist.separateSongSettings ? song.applying(entry) : song
        }
    }
}
public enum LibraryError: LocalizedError {
    case invalidFormat, sameSourceAndDestination
    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "This file is not a complete JustChords library. The last working library has been kept."
        case .sameSourceAndDestination: return "Choose a separate Mac Looper folder. The JustChords source must remain read-only."
        }
    }
}

public enum ChordTransposition {
    public static func pitch(_ name: String) -> Int? {
        let chars = Array(name.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b"))
        guard let first = chars.first, let n = ["C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11][String(first)] else { return nil }
        return (n + (chars.count > 1 && chars[1] == "#" ? 1 : chars.count > 1 && chars[1] == "b" ? -1 : 0) + 12) % 12
    }
    public static func transpose(_ chord: String, semitones: Int, flats: Bool) -> String {
        guard semitones % 12 != 0 else { return chord }
        let names = flats ? ["C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"] : ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return chord.components(separatedBy: "/").map { part in
            guard let p = pitch(part), let first = part.first, ("ABCDEFG".contains(first)) else { return part }
            let chars = Array(part)
            let count = chars.count > 1 && ["#","b","♯","♭"].contains(chars[1]) ? 2 : 1
            return names[(p + semitones % 12 + 12) % 12] + String(chars.dropFirst(count))
        }.joined(separator: "/")
    }
}
