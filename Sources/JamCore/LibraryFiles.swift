import Foundation

public actor LibraryFiles {
    let conflictVersions: (URL) throws -> [LibraryConflictVersion]
    let markConflictResolved: (LibraryConflictVersion, URL) throws -> Void
    let refreshCloudFile: (URL) async throws -> Void
    public init(conflictVersions: ((URL) throws -> [LibraryConflictVersion])? = nil,
                markConflictResolved: ((LibraryConflictVersion, URL) throws -> Void)? = nil,
                refreshCloudFile: ((URL) async throws -> Void)? = nil) {
        self.conflictVersions = conflictVersions ?? Self.systemConflictVersions
        self.markConflictResolved = markConflictResolved ?? Self.markSystemConflictResolved
        self.refreshCloudFile = refreshCloudFile ?? Self.downloadCurrentCloudFile
    }
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

public enum LibraryCloudRefreshError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "iCloud hasn’t updated the library yet. Showing the downloaded copy. \(reason)"
        }
    }
}

extension LibraryFiles {
    static func downloadCurrentCloudFile(_ url: URL) async throws {
        try await waitForCurrentCloudFile(url, status: { url in
            var fresh = url
            fresh.removeAllCachedResourceValues()
            let values = try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            guard values.isUbiquitousItem == true else { return nil }
            return values.ubiquitousItemDownloadingStatus ?? .notDownloaded
        }, request: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
           pause: { try await Task.sleep(for: .milliseconds(250)) })
    }

    // Bounded launch/foreground refresh only; no periodic library polling.
    static func waitForCurrentCloudFile(_ url: URL,
        status: (URL) throws -> URLUbiquitousItemDownloadingStatus?,
        request: (URL) throws -> Void, pause: () async throws -> Void, attempts: Int = 120) async throws {
        guard try status(url) != nil else { return }
        do {
            try Task.checkCancellation()
            // Request even for a local copy currently marked current: iCloud may
            // not have discovered the other device’s revision when we launch.
            try request(url)
            for _ in 0..<attempts {
                try Task.checkCancellation()
                if try status(url) == .current { return }
                try await pause()
            }
            throw LibraryCloudRefreshError.unavailable("Try opening the app again when connected.")
        } catch is CancellationError { throw CancellationError() }
        catch let error as LibraryCloudRefreshError { throw error }
        catch { throw LibraryCloudRefreshError.unavailable(error.localizedDescription) }
    }
}

public extension LibraryFiles {
    static func songMediaURL(relativePath: String, in folder: URL) -> URL? {
        // Work with path components so a provider's /var and /private/var
        // aliases work even before it downloads a file.
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        var result = folder
        for part in parts {
            result.appendPathComponent(String(part))
            if (try? result.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return nil }
        }
        return result
    }

    static func songLoopURL(named name: String, in folder: URL) -> URL? {
        guard !name.contains("/"), !name.hasPrefix("."), name.lowercased().hasSuffix(".jamloop") else { return nil }
        return songMediaURL(relativePath: "Loops/" + name, in: folder)
    }

    func prepareSongBacking(_ url: URL) async throws {
        try await refreshCloudFile(url)
        try Task.checkCancellation()
    }

    func backingTracks(in folder: URL) throws -> [String: URL] {
        let manifest = folder.appendingPathComponent("backing-tracks.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [:] }
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        return values.compactMapValues { Self.songMediaURL(relativePath: $0, in: folder) }
    }

    internal func copySongBacking(_ source: URL, into folder: URL) throws -> (url: URL, path: String) {
        let relative = "Backing Tracks/\(UUID().uuidString)/\(source.lastPathComponent)"
        let destination = try copyBacking(source, relativePath: relative, into: folder)
        return (destination, relative)
    }

    private func copyBacking(_ source: URL, relativePath: String, into folder: URL) throws -> URL {
        guard source.isFileURL, let destination = Self.songMediaURL(relativePath: relativePath, in: folder) else {
            throw LibraryError.invalidFormat
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var coordinationError: NSError?, copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: [], error: &coordinationError) { read, write in
            do {
                let values = try read.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.invalidFormat }
                try FileManager.default.copyItem(at: read, to: write)
            } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }

    func attachBacking(_ source: URL, songID: String, in folder: URL) throws -> URL {
        let safeID = String(songID.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(80))
        guard !safeID.isEmpty else { throw LibraryError.invalidFormat }
        let relative = "Backing Tracks/\(safeID)/\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)"
        let destination = try copyBacking(source, relativePath: relative, into: folder)
        var error: NSError?
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
