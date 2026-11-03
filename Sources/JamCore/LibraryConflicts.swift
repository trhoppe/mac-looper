import Foundation
import CryptoKit

public struct LibraryConflictVersion: Sendable {
    public let id: String
    public let data: Data
    public let date: Date?
    public let device: String?
    public init(id: String, data: Data, date: Date? = nil, device: String? = nil) {
        self.id = id; self.data = data; self.date = date; self.device = device
    }
}
public struct LibraryConflictCopy: Identifiable, Sendable {
    public let id: String
    public let data: Data
    public let date: Date?
    public let device: String?
    public var isCurrent: Bool { id == "current" }
    public var digest: String { Self.digest(data) }
    public var songs: [LibrarySong] { (try? JustChordsLibrary(data: data))?.songs ?? [] }
    public var isValid: Bool { (try? JustChordsLibrary(data: data)) != nil }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public extension LibraryFiles {
    static func systemConflictVersions(at url: URL) throws -> [LibraryConflictVersion] {
        try (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map {
            LibraryConflictVersion(id: $0.url.absoluteString, data: try Data(contentsOf: $0.url),
                                   date: $0.modificationDate, device: $0.localizedNameOfSavingComputer)
        }
    }
    static func markSystemConflictResolved(_ version: LibraryConflictVersion, at url: URL) throws {
        guard let current = NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.first(where: { $0.url.absoluteString == version.id }),
              try Data(contentsOf: current.url) == version.data else { throw SongEditError.conflictsChanged }
        current.isResolved = true
    }
    /// Retain exact copies before offering a choice. Never silently choose the
    /// newest device, overwrite a version, or mark a conflict resolved on launch.
    func conflictCopies(at destination: URL) throws -> [LibraryConflictCopy] {
        guard !Self.isProtectedLibrary(destination) else { throw SongEditError.protectedLibrary }
        var coordinationError: NSError?, operationError: Error?, copies: [LibraryConflictCopy] = []
        NSFileCoordinator().coordinate(readingItemAt: destination, options: [], error: &coordinationError) { file in
            do {
                let versions = try conflictVersions(file)
                guard !versions.isEmpty else { return }
                let current = try Data(contentsOf: file)
                copies = [LibraryConflictCopy(id: "current", data: current, date: nil, device: nil)] + versions.map {
                    LibraryConflictCopy(id: $0.id, data: $0.data, date: $0.date, device: $0.device)
                }
                try Self.backupConflictCopies(copies, beside: destination)
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }; if let operationError { throw operationError }
        return copies
    }
    static func backupConflictCopies(_ copies: [LibraryConflictCopy], beside destination: URL) throws {
        let folder = destination.deletingLastPathComponent().appendingPathComponent("Library Conflicts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for copy in copies {
            let url = folder.appendingPathComponent("library-" + copy.digest + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                guard try Data(contentsOf: url) == copy.data else { throw SongEditError.conflictsChanged }
            } else { try copy.data.write(to: url, options: .atomic) }
        }
    }
    func resolveConflict(using selectedID: String, expected: [LibraryConflictCopy], at destination: URL) throws -> JustChordsLibrary {
        guard !Self.isProtectedLibrary(destination) else { throw SongEditError.protectedLibrary }
        guard let chosen = expected.first(where: { $0.id == selectedID }) else { throw SongEditError.conflictsChanged }
        let selected = try JustChordsLibrary(data: chosen.data).migratingToChordPro()
        var coordinationError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { file in
            do {
                let versions = try conflictVersions(file)
                let current = LibraryConflictCopy(id: "current", data: try Data(contentsOf: file), date: nil, device: nil)
                let actual = [current] + versions.map { LibraryConflictCopy(id: $0.id, data: $0.data, date: $0.date, device: $0.device) }
                let fingerprints: ([LibraryConflictCopy]) -> [String: String] = { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0.digest) }) }
                guard !versions.isEmpty, fingerprints(actual) == fingerprints(expected) else { throw SongEditError.conflictsChanged }
                try Self.backupConflictCopies(actual, beside: destination)
                try selected.originalData.write(to: file, options: .atomic)
                // Only the versions reviewed by the user are acknowledged. Copies
                // stay on disk; removeOtherVersions is deliberately not called.
                for version in versions { try markConflictResolved(version, file) }
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }; if let operationError { throw operationError }
        return selected
    }
}
