import Foundation

public struct SongDraft: Identifiable, Equatable, Sendable {
    public let original: LibrarySong
    public var id: String { original.id }
    public var title: String
    public var artist: String
    public var key: String
    public var tempo: String
    public var timeSignature: String
    public var duration: String
    public var chordPro: String

    public init(song: LibrarySong) {
        original = song
        title = song.title; artist = song.artist
        key = (song.originalKey ?? "") + (song.fields["keyChord"]?.object["minor"]?.boolean == true ? "m" : "")
        tempo = song.fields["tempo"]?.text ?? ""
        timeSignature = song.fields["timeSignature"]?.text ?? ""
        duration = song.fields["duration"]?.text ?? ""
        chordPro = song.chordPro
    }
    public var hasChanges: Bool { self != SongDraft(song: original) }
    public var validationError: String? {
        do { _ = try changes(); return nil } catch { return error.localizedDescription }
    }
    /// Only explicitly changed fields are patched; unknown fields stay intact.
    /// A null change removes an optional metadata field.
    public func changes() throws -> [String: JSONValue] {
        let before = SongDraft(song: original)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SongEditError.validation("Enter a song name.") }
        var edits: [String: JSONValue] = [:]
        if self.title != before.title { edits["title"] = .string(title) }
        if artist != before.artist { edits["artist"] = .string(artist.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if chordPro != before.chordPro { edits["rawData"] = .string(chordPro) }
        if key != before.key {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { edits["keyChord"] = .null }
            else {
                guard value.range(of: #"^[A-Ga-g](?:#|b|♯|♭)?m?$"#, options: .regularExpression) != nil else {
                    throw SongEditError.validation("Use a key such as C, F# or Am.")
                }
                let minor = value.hasSuffix("m")
                let root = String((minor ? String(value.dropLast()) : value).prefix(1)).uppercased()
                    + String((minor ? String(value.dropLast()) : value).dropFirst()).replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
                var fields = original.fields["keyChord"]?.object ?? [:]
                fields["key"] = .string(root); fields["minor"] = .bool(minor)
                edits["keyChord"] = .object(fields)
            }
            // A changed base key must not remain hidden by an old display transpose.
            if original.fields["transpose"] != nil { edits["transpose"] = .null }
        }
        if tempo != before.tempo {
            let value = tempo.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { edits["tempo"] = .null }
            else {
                guard let bpm = Double(value), bpm.isFinite, bpm > 0, bpm <= 999 else {
                    throw SongEditError.validation("Enter a BPM between 1 and 999, or leave it blank.")
                }
                if case .number = original.fields["tempo"] { edits["tempo"] = .number(bpm) }
                else { edits["tempo"] = .string(value) }
            }
        }
        if timeSignature != before.timeSignature {
            let value = timeSignature.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { edits["timeSignature"] = .null }
            else {
                let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, let beats = Int(parts[0]), (1...32).contains(beats),
                      let unit = Int(parts[1]), [1, 2, 4, 8, 16, 32, 64].contains(unit) else {
                    throw SongEditError.validation("Use a time signature such as 4/4, 3/4 or 6/8.")
                }
                edits["timeSignature"] = .string("\(beats)/\(unit)")
            }
        }
        if duration != before.duration {
            let value = duration.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { edits["duration"] = .null }
            else {
                let parts = value.split(separator: ":", omittingEmptySubsequences: false)
                let numbers = parts.compactMap { Int($0) }
                guard (2...3).contains(parts.count), numbers.count == parts.count,
                      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                      numbers.allSatisfy({ $0 >= 0 && $0 <= 9999 }), numbers.last! < 60,
                      parts.count != 3 || numbers[1] < 60 else {
                    throw SongEditError.validation("Enter length as minutes:seconds, such as 3:45.")
                }
                edits["duration"] = .string(value)
            }
        }
        return edits.filter { field, value in
            value == .null ? original.fields[field] != nil : original.fields[field] != value
        }
    }
}

public enum SongEditError: LocalizedError {
    case validation(String), missingSong, conflict, protectedLibrary
    public var errorDescription: String? {
        switch self {
        case .validation(let message): return message
        case .missingSong: return "This song is no longer in the library. Your changes have not been saved."
        case .conflict: return "This song changed on another device. Your draft is still here. Cancel and reopen Edit to load the latest version before saving."
        case .protectedLibrary: return "Choose the Mac Jams library folder, separate from JustChords. Its original library stays unchanged."
        }
    }
}
