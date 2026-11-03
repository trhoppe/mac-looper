import Foundation
import CryptoKit

/// Keeps the editor's original version as well as its new text, so recovery still
/// uses the normal three-way merge rather than silently overwriting newer edits.
public struct RecoveredSongDraft: Codable, Identifiable, Sendable {
    public let library: String
    public let originalFields: [String: JSONValue]
    public let chordPro: String
    public let newSong: Bool?
    public let originalPlaylistIDs: Set<String>?
    public let playlistIDs: Set<String>?
    public let updatedAt: Date
    public var id: String { originalFields["id"]?.text ?? "" }
    public var draft: SongDraft {
        var value = newSong == true ? SongDraft(newSongID: id) : SongDraft(song: LibrarySong(fields: originalFields), playlistIDs: originalPlaylistIDs)
        if let playlistIDs { value.playlistIDs = playlistIDs }
        value.chordPro = chordPro
        return value
    }
    public init(draft: SongDraft, library: URL, updatedAt: Date = Date()) {
        self.library = Self.identity(library); originalFields = draft.original.fields
        chordPro = draft.chordPro; self.updatedAt = updatedAt
        newSong = draft.isNew; originalPlaylistIDs = draft.originalPlaylistIDs; playlistIDs = draft.playlistIDs
    }
    public static func identity(_ library: URL) -> String { library.standardizedFileURL.resolvingSymlinksInPath().path }
}

/// Device-local recovery, deliberately outside iCloud. Atomic writes are serialized
/// off the UI actor. Sequence numbers prevent older queued writes resurrecting a
/// discarded/saved draft. A malformed recovery file is retained for inspection.
public actor SongDraftRecoveryStore {
    private let folder: URL
    private var sequences: [String: Int] = [:]
    public init(folder: URL) { self.folder = folder }
    private func key(library: String, songID: String) -> String {
        SHA256.hash(data: Data((library + "\u{0}" + songID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func write(_ recovery: RecoveredSongDraft?, library: URL, songID: String, sequence: Int) throws {
        let identity = RecoveredSongDraft.identity(library), key = key(library: identity, songID: songID)
        guard sequence > (sequences[key] ?? -1) else { return }
        let url = folder.appendingPathComponent(key + ".json")
        if let recovery {
            guard recovery.library == identity, recovery.id == songID else { throw LibraryError.invalidFormat }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(recovery).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        sequences[key] = sequence
    }
    public func drafts(in library: URL) throws -> [RecoveredSongDraft] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let identity = RecoveredSongDraft.identity(library)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url -> RecoveredSongDraft? in
                // One damaged record must not hide other recoverable songs.
                // Leave its bytes intact; never delete unreadable recovery files.
                guard let bytes = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(RecoveredSongDraft.self, from: bytes) else { return nil }
                return value.library == identity ? value : nil
            }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
