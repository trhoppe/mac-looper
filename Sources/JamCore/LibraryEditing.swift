import Foundation

public extension JustChordsLibrary {
    /// Re-read/patch the original JSON representation so large numeric values in
    /// unknown fields never pass through JSONValue's Double representation.
    func applying(_ draft: SongDraft, modifiedAt: Date = Date()) throws -> JustChordsLibrary {
        _ = try draft.changes()
        guard draft.hasChanges else { return self }
        let current = songs.first(where: { $0.id == draft.id })
        guard draft.isNew || current != nil else { throw SongEditError.missingSong }
        if draft.isNew, let current, current.chordPro != draft.chordPro { throw SongEditError.conflict }
        guard var root = try JSONSerialization.jsonObject(with: originalData) as? [String: Any],
              var entries = root["songs"] as? [[String: Any]] else { throw LibraryError.invalidFormat }
        var changed = false
        if let current, let index = songs.firstIndex(where: { $0.id == draft.id }) {
            let merged = try ChordProSongSource.merging(base: SongDraft(song: draft.original).chordPro,
                edited: draft.chordPro, latest: SongDraft(song: current).chordPro)
            var mergedDraft = SongDraft(song: current); mergedDraft.chordPro = merged
            let edits = try mergedDraft.changes()
            if !edits.isEmpty {
                try Self.patch(edits, into: &entries[index])
                entries[index]["date"] = modifiedAt.timeIntervalSinceReferenceDate
                changed = true
            }
        } else {
            var entry: [String: Any] = ["id": draft.id]
            try Self.patch(draft.changes(), into: &entry)
            entry["date"] = modifiedAt.timeIntervalSinceReferenceDate
            entries.append(entry); changed = true
        }
        root["songs"] = entries
        if let base = draft.originalPlaylistIDs {
            let memberships = playlistIDs(containing: draft.id)
            let touched = draft.isNew ? draft.playlistIDs : base.symmetricDifference(draft.playlistIDs)
            let available = Set(playlists.map(\.id))
            guard draft.playlistIDs.intersection(touched).isSubset(of: available) else {
                throw SongEditError.validation("A selected playlist was removed on another device. Reopen the song to choose its playlists.")
            }
            guard var lists = root["playlists"] as? [[String: Any]] else { throw LibraryError.invalidFormat }
            for index in lists.indices {
                let id = Self.identifier(lists[index]["id"])
                guard touched.contains(id) else { continue }
                let included = draft.playlistIDs.contains(id)
                guard included != memberships.contains(id) else { continue }
                var arrangement = lists[index]["arrangement"] as? [Any] ?? []
                if included {
                    arrangement.append(["type": "song", "id": entries.first { Self.identifier($0["id"]) == draft.id }!["id"]!,
                                        "index": UUID().uuidString])
                } else { arrangement = Self.removingSong(draft.id, from: arrangement) }
                lists[index]["arrangement"] = arrangement
                lists[index]["date"] = modifiedAt.timeIntervalSinceReferenceDate
                changed = true
            }
            root["playlists"] = lists
        }
        guard changed else { return self }
        return try JustChordsLibrary(data: JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
    }
    private static func identifier(_ value: Any?) -> String {
        if let value = value as? String { return value }
        return (value as? NSNumber)?.stringValue ?? ""
    }
    private static func removingSong(_ id: String, from items: [Any]) -> [Any] {
        items.compactMap { value in
            guard let item = value as? [String: Any] else { return value }
            if item["type"] as? String == "song", identifier(item["id"]) == id { return nil }
            var copy = item
            if let nested = item["arrangement"] as? [Any] { copy["arrangement"] = removingSong(id, from: nested) }
            return copy
        }
    }

}

public extension LibraryFiles {
    static func isProtectedLibrary(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.contains {
            $0.localizedCaseInsensitiveContains("iCloud~online~justchords~JustChords")
        }
    }
    /// Coordinate one read-modify-write against iCloud. Other songs/fields changed
    /// since the editor opened are merged; edited-field conflicts keep the draft.
    func save(_ draft: SongDraft, to destination: URL) throws -> JustChordsLibrary {
        guard !Self.isProtectedLibrary(destination) else { throw SongEditError.protectedLibrary }
        var coordinationError: NSError?, operationError: Error?, result: JustChordsLibrary?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { file in
            do {
                guard try conflictVersions(file).isEmpty else { throw SongEditError.unresolvedCloudConflict }
                let previous = try Data(contentsOf: file)
                let latest = try JustChordsLibrary(data: previous)
                let updated = try latest.applying(draft)
                if updated.originalData != previous {
                    let backups = file.deletingLastPathComponent().appendingPathComponent("Library Backups", isDirectory: true)
                    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    let backup = backups.appendingPathComponent("library-\(stamp)-\(UUID().uuidString).json")
                    try previous.write(to: backup, options: .atomic)
                    try updated.originalData.write(to: file, options: .atomic)
                }
                result = updated
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        guard let result else { throw LibraryError.invalidFormat }
        return result
    }
}

public extension JustChordsLibrary {
    /// One-time, idempotent conversion. IDs, playlists, unknown fields and numeric
    /// values are patched through JSONSerialization without lossy re-encoding.
    func migratingToChordPro() throws -> JustChordsLibrary {
        guard songs.contains(where: { !$0.isChordProNative }) else { return self }
        guard var root = try JSONSerialization.jsonObject(with: originalData) as? [String: Any],
              var entries = root["songs"] as? [[String: Any]] else { throw LibraryError.invalidFormat }
        for (index, song) in songs.enumerated() where !song.isChordProNative {
            let seeded = ChordProSongSource(ChordProSongSource.seeded(from: song))
            let source = ChordProSongSource.render(seeded.values, body: ChordProSongSource.standardizingLegacyBody(seeded.body))
            var edits = SongDraft.compatibilityFields(source: ChordProSongSource(source), original: song)
            edits["rawData"] = .string(source); edits["macJamsChordProVersion"] = .number(1)
            try Self.patch(edits, into: &entries[index])
        }
        root["songs"] = entries
        return try JustChordsLibrary(data: JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
    }
    private static func patch(_ edits: [String: JSONValue], into entry: inout [String: Any]) throws {
        for (field, value) in edits {
            if value == .null { entry.removeValue(forKey: field) }
            else if field == "keyChord", case .object(let key) = value {
                var existing = entry[field] as? [String: Any] ?? [:]
                existing["key"] = key["key"]?.text; existing["minor"] = key["minor"]?.boolean ?? false
                entry[field] = existing
            } else {
                entry[field] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
            }
        }
    }
}

public extension LibraryFiles {
    /// App launches/foreground refreshes migrate only an existing own library.
    /// The exact prior file is durably backed up before the atomic replacement.
    func prepareChordProLibrary(at destination: URL) async throws -> JustChordsLibrary {
        guard !Self.isProtectedLibrary(destination) else { throw SongEditError.protectedLibrary }
        try await refreshCloudFile(destination)
        try Task.checkCancellation()
        // A coordinated read materializes provider-backed files before any
        // migration asks for write access. Most launches need no write at all.
        let current = try read(destination)
        guard try current.migratingToChordPro().originalData != current.originalData else { return current }
        var coordinationError: NSError?, operationError: Error?, result: JustChordsLibrary?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { file in
            do {
                let previous = try Data(contentsOf: file)
                let latest = try JustChordsLibrary(data: previous)
                guard try conflictVersions(file).isEmpty else { result = latest; return }
                let updated = try latest.migratingToChordPro()
                if updated.originalData != previous {
                    let backups = file.deletingLastPathComponent().appendingPathComponent("Library Backups", isDirectory: true)
                    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    let backup = backups.appendingPathComponent("library-before-chordpro-\(stamp)-\(UUID().uuidString).json")
                    try previous.write(to: backup, options: .atomic)
                    try updated.originalData.write(to: file, options: .atomic)
                }
                result = updated
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        guard let result else { throw LibraryError.invalidFormat }
        return result
    }
}
