import Foundation

public struct SavedLoopFile: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public init(url: URL) { self.url = url }
}

public enum LoopStorageError: LocalizedError {
    case chooseLibrary, invalidName, downloadPending(String), cloudConflict
    public var errorDescription: String? {
        switch self {
        case .chooseLibrary: "Choose your shared chord-library folder in Settings before saving loops."
        case .invalidName: "Enter a shorter loop name without slashes, colons, or a leading period."
        case .downloadPending(let detail): "This loop isn’t available from iCloud yet. Check your connection and try again. \(detail)"
        case .cloudConflict: "iCloud has conflicting versions of this loop. Resolve the versions in iCloud Drive before opening it."
        }
    }
}

/// Uses the same user-granted folder as the chord library. iCloud Drive handles
/// transport; all coordination, downloads, and PCM validation stay off the UI
/// and render threads. Every save creates a file and never replaces an old take.
public actor LoopFiles {
    private let refreshCloudFile: (URL) async throws -> Void
    public init(refreshCloudFile: ((URL) async throws -> Void)? = nil) {
        self.refreshCloudFile = refreshCloudFile ?? LibraryFiles.downloadCurrentCloudFile
    }
    public static func folder(in library: URL) -> URL { library.appendingPathComponent("Loops", isDirectory: true) }

    public func list(in library: URL) throws -> [SavedLoopFile] {
        let access = library.startAccessingSecurityScopedResource()
        defer { if access { library.stopAccessingSecurityScopedResource() } }
        let folder = try checkedFolder(in: library, create: false)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        var coordinationError: NSError?, readError: Error?, entries: [SavedLoopFile] = []
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinationError) { directory in
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                var unique: [String: SavedLoopFile] = [:]
                for url in urls {
                    let name = url.lastPathComponent
                    let placeholder = name.hasPrefix(".") && name.lowercased().hasSuffix(".jamloop.icloud")
                    guard placeholder || (!name.hasPrefix(".") && url.pathExtension.lowercased() == "jamloop") else { continue }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                    let resolved = placeholder ? directory.appendingPathComponent(String(name.dropFirst().dropLast(7))) : url
                    unique[resolved.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()] = SavedLoopFile(url: resolved)
                }
                entries = unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch { readError = error }
        }
        if let coordinationError { throw coordinationError }; if let readError { throw readError }
        return entries
    }

    public func save(_ data: Data, name: String, in library: URL) throws -> SavedLoopFile {
        _ = try SavedLoop.decode(data)
        return try write(data, name: name, in: library)
    }

    public func save(_ loop: SavedLoop, name: String, in library: URL) throws -> SavedLoopFile {
        try write(loop.encoded(), name: name, in: library)
    }

    private func write(_ data: Data, name: String, in library: URL) throws -> SavedLoopFile {
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if title.lowercased().hasSuffix(".jamloop") { title = String(title.dropLast(8)) }
        guard !title.isEmpty, !title.hasPrefix("."), title.utf8.count <= 140,
              title.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil else { throw LoopStorageError.invalidName }
        let access = library.startAccessingSecurityScopedResource()
        defer { if access { library.stopAccessingSecurityScopedResource() } }
        let folder = try checkedFolder(in: library, create: true)
        var coordinationError: NSError?, writeError: Error?, result: SavedLoopFile?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { directory in
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).pending")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let existing = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).map { $0.precomposedStringWithCanonicalMapping.lowercased() })
                var number = 1, filename = title + ".jamloop"
                while existing.contains(filename.lowercased()) || existing.contains("." + filename.lowercased() + ".icloud") {
                    number += 1; filename = "\(title) (\(number)).jamloop"
                }
                try data.write(to: temporary, options: .atomic)
                let destination = directory.appendingPathComponent(filename)
                // Same-directory rename publishes a complete file and refuses
                // to overwrite even if another writer won the destination.
                try FileManager.default.moveItem(at: temporary, to: destination)
                result = SavedLoopFile(url: destination)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }; if let writeError { throw writeError }
        guard let result else { throw LoopFileError.transfer }
        return result
    }

    public func read(_ url: URL) async throws -> SavedLoop {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try await refreshCloudFile(url) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LoopStorageError.downloadPending(error.localizedDescription) }
        var coordinationError: NSError?, readError: Error?, loop: SavedLoop?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            do {
                guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).isEmpty else { throw LoopStorageError.cloudConflict }
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= SavedLoop.maximumFileBytes else { throw LoopFileError.invalid }
                loop = try SavedLoop.decode(Data(contentsOf: file))
            } catch { readError = error }
        }
        if let coordinationError { throw coordinationError }; if let readError { throw readError }
        guard let loop else { throw LoopFileError.invalid }; return loop
    }

    private func checkedFolder(in library: URL, create: Bool) throws -> URL {
        let values = try? library.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { throw LoopStorageError.chooseLibrary }
        let folder = Self.folder(in: library)
        if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LoopStorageError.chooseLibrary }
        if create { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return folder
    }
}
