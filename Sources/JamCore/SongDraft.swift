import Foundation

public struct SongDraft: Identifiable, Equatable, Sendable {
    public let original: LibrarySong
    public let isNew: Bool
    public let originalPlaylistIDs: Set<String>?
    public var playlistIDs: Set<String>
    private let initialPlaylistIDs: Set<String>
    public var id: String { original.id }
    private let initialSource: String
    private var metadata: ChordProSongSource
    public var chordPro: String { didSet { metadata = ChordProSongSource(chordPro) } }
    public var title: String { get { metadata.first("title") ?? "" } set { set("title", newValue) } }
    public var artist: String { get { metadata.values["artist"]?.joined(separator: ", ") ?? "" } set { set("artist", newValue) } }
    public var key: String { get { metadata.first("key") ?? "" } set { set("key", newValue) } }
    public var tempo: String { get { metadata.first("tempo") ?? "" } set { set("tempo", newValue) } }
    public var timeSignature: String { get { metadata.first("time") ?? "" } set { set("time", newValue) } }
    public var duration: String { get { metadata.first("duration") ?? "" } set { set("duration", newValue) } }
    private mutating func set(_ name: String, _ value: String) {
        chordPro = metadata.setting(name, to: value.components(separatedBy: .newlines).joined(separator: " "))
    }
    public init(song: LibrarySong, playlistIDs: Set<String>? = nil) {
        original = song; isNew = false
        originalPlaylistIDs = playlistIDs; self.playlistIDs = playlistIDs ?? []
        initialPlaylistIDs = playlistIDs ?? []
        let source = song.isChordProNative ? song.chordPro : ChordProSongSource.seeded(from: song)
        initialSource = source; chordPro = source; metadata = ChordProSongSource(source)
    }
    public init(newSongID: String = UUID().uuidString, playlistIDs: Set<String> = []) {
        original = LibrarySong(fields: ["id": .string(newSongID), "rawData": .string(""), "macJamsChordProVersion": .number(1)])
        isNew = true; originalPlaylistIDs = []; self.playlistIDs = playlistIDs; initialPlaylistIDs = playlistIDs
        initialSource = ""; chordPro = ""; metadata = ChordProSongSource("")
    }
    public var hasChanges: Bool { chordPro != initialSource || playlistIDs != initialPlaylistIDs }
    public var validationError: String? {
        do { _ = try changes(); return nil } catch { return error.localizedDescription }
    }
    public func changes() throws -> [String: JSONValue] {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw SongEditError.validation("Enter a song name or a {title: ...} directive.") }
        if !key.isEmpty && key.range(of: #"^[A-Ga-g](?:#|b|♯|♭)?m?$"#, options: .regularExpression) == nil {
            throw SongEditError.validation("Use a key such as C, F# or Am.")
        }
        if !tempo.isEmpty {
            guard let bpm = Double(tempo), bpm.isFinite, bpm > 0, bpm <= 999 else {
                throw SongEditError.validation("Enter a BPM between 1 and 999, or leave it blank.")
            }
        }
        if !timeSignature.isEmpty {
            let parts = timeSignature.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let beats = Int(parts[0]), (1...32).contains(beats),
                  let unit = Int(parts[1]), [1, 2, 4, 8, 16, 32, 64].contains(unit) else {
                throw SongEditError.validation("Use a time signature such as 4/4, 3/4 or 6/8.")
            }
        }
        if !duration.isEmpty {
            let parts = duration.split(separator: ":", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            let seconds = parts.count == 1 && Int(duration).map { $0 >= 0 } == true
            guard seconds || ((2...3).contains(parts.count) && numbers.count == parts.count &&
                parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) &&
                numbers.allSatisfy({ $0 >= 0 && $0 <= 9999 }) && numbers.last! < 60 &&
                (parts.count != 3 || numbers[1] < 60)) else {
                throw SongEditError.validation("Enter length as minutes:seconds (3:45) or seconds (225).")
            }
        }
        guard hasChanges else { return [:] }
        var edits = Self.compatibilityFields(source: metadata, original: original)
        edits["rawData"] = .string(chordPro)
        edits["macJamsChordProVersion"] = .number(1)
        if key != SongDraft(song: original).key, original.fields["transpose"] != nil { edits["transpose"] = .null }
        if isNew { return edits.filter { $0.value != .null } }
        return edits.filter { field, value in value == .null ? original.fields[field] != nil : original.fields[field] != value }
    }
    /// Legacy JSON is a compatibility mirror of the canonical ChordPro preamble.
    static func compatibilityFields(source: ChordProSongSource, original: LibrarySong) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (directive, field) in [("title", "title"), ("artist", "artist"), ("time", "timeSignature"), ("duration", "duration"), ("capo", "capo"), ("tempo", "tempo")] {
            let value = directive == "artist" ? source.values[directive]?.joined(separator: ", ") : source.first(directive)
            if let value, !value.isEmpty {
                if case .number = original.fields[field], let number = Double(value), number.isFinite { result[field] = .number(number) }
                else { result[field] = .string(value) }
            } else { result[field] = .null }
        }
        if let value = source.first("key"), !value.isEmpty {
            let minor = value.hasSuffix("m"), raw = value.hasSuffix("m") ? String(value.dropLast()) : value
            let root = String(raw.prefix(1)).uppercased() + raw.dropFirst().replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
            var fields = original.fields["keyChord"]?.object ?? [:]
            fields["key"] = .string(root); fields["minor"] = .bool(minor)
            result["keyChord"] = .object(fields)
        } else { result["keyChord"] = .null }
        return result
    }
}

public enum SongEditError: LocalizedError {
    case validation(String), missingSong, conflict, protectedLibrary, unresolvedCloudConflict, conflictsChanged
    public var errorDescription: String? {
        switch self {
        case .validation(let message): return message
        case .missingSong: return "This song is no longer in the library. Your changes have not been saved."
        case .conflict: return "This song changed on another device. Your draft is still here. Your recovery copy has been kept. Copy your ChordPro before discarding this draft, then reopen Edit to review the latest version."
        case .unresolvedCloudConflict: return "iCloud has conflicting library versions. Your draft is safe. Review the versions in Settings before saving."
        case .conflictsChanged: return "The library changed while you were reviewing it. Refresh the versions and choose again. All copies have been kept."
        case .protectedLibrary: return "Choose the Mac Jams library folder, separate from JustChords. Its original library stays unchanged."
        }
    }
}
