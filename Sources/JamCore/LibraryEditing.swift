import Foundation

public extension JustChordsLibrary {
    /// Re-read/patch the original JSON representation so large numeric values in
    /// unknown fields never pass through JSONValue's Double representation.
    func applying(_ draft: SongDraft, modifiedAt: Date = Date()) throws -> JustChordsLibrary {
        let edits = try draft.changes()
        guard !edits.isEmpty else { return self }
        guard let current = songs.first(where: { $0.id == draft.id }) else { throw SongEditError.missingSong }
        for (field, proposed) in edits {
            let latest = current.fields[field]
            let desired: JSONValue? = proposed == .null ? nil : proposed
            guard latest == draft.original.fields[field] || latest == desired else { throw SongEditError.conflict }
        }
        if edits.allSatisfy({ field, proposed in current.fields[field] == (proposed == .null ? nil : proposed) }) { return self }
        guard var root = try JSONSerialization.jsonObject(with: originalData) as? [String: Any],
              var songs = root["songs"] as? [[String: Any]],
              let index = self.songs.firstIndex(where: { $0.id == draft.id }) else { throw SongEditError.missingSong }
        for (field, value) in edits {
            if value == .null { songs[index].removeValue(forKey: field) }
            else if field == "keyChord", case .object(let key) = value {
                // Preserve unknown nested numeric values without converting them
                // through the portable viewer's Double-backed JSONValue model.
                var existing = songs[index][field] as? [String: Any] ?? [:]
                existing["key"] = key["key"]?.text
                existing["minor"] = key["minor"]?.boolean ?? false
                songs[index][field] = existing
            } else {
                let bytes = try JSONEncoder().encode(value)
                songs[index][field] = try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)
            }
        }
        // JustChords stores dates in seconds since Apple's 2001 reference date.
        songs[index]["date"] = modifiedAt.timeIntervalSinceReferenceDate
        root["songs"] = songs
        return try JustChordsLibrary(data: JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
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
