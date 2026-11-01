import Foundation

public actor LibraryFiles {
    public init() { }
    public func read(_ url: URL) throws -> JustChordsLibrary {
        var error: NSError?, readError: Error?, bytes: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { file in
            do { bytes = try Data(contentsOf: file) } catch { readError = error }
        }
        if let error { throw error }; if let readError { throw readError }
        guard let bytes else { throw LibraryError.invalidFormat }
        return try JustChordsLibrary(data: bytes)
    }
    // Validate before replacing. The source is never written. Write exact original
    // bytes atomically so unknown fields and JustChords compatibility remain intact.
    public func mirror(_ library: JustChordsLibrary, to destination: URL, source: URL?) throws {
        if let source, source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() { throw LibraryError.sameSourceAndDestination }
        _ = try JustChordsLibrary(data: library.originalData)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: destination)) == library.originalData { return }
        var error: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &error) { file in
            do { try library.originalData.write(to: file, options: .atomic) } catch { writeError = error }
        }
        if let error { throw error }; if let writeError { throw writeError }
    }
}

public extension LibraryFiles {
    func backingTracks(in folder: URL) throws -> [String: URL] {
        let manifest = folder.appendingPathComponent("backing-tracks.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [:] }
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        return values.reduce(into: [:]) { result, item in
            // Validate relative components without canonicalizing the sandbox root.
            // iPadOS can spell the same container /var or /private/var; comparing
            // standardized string prefixes can reject valid, not-yet-downloaded files.
            let parts = item.value.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return }
            var url = folder
            for part in parts {
                url.appendPathComponent(String(part))
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return }
            }
            result[item.key] = url
        }
    }

    func attachBacking(_ source: URL, songID: String, in folder: URL) throws -> URL {
        let safeID = String(songID.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(80))
        guard !safeID.isEmpty else { throw LibraryError.invalidFormat }
        let relative = "Backing Tracks/\(safeID)/\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)"
        let destination = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?, copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: [], error: &error) { read, write in
            do { try FileManager.default.copyItem(at: read, to: write) } catch { copyError = error }
        }
        if let error { throw error }; if let copyError { throw copyError }
        let manifest = folder.appendingPathComponent("backing-tracks.json")
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: manifest, options: .forReplacing, error: &error) { url in
            do {
                var values = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
                values[songID] = relative
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(values).write(to: url, options: .atomic)
            } catch { writeError = error }
        }
        if let error { throw error }; if let writeError { throw writeError }
        return destination
    }
}
