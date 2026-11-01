import Foundation
import UniformTypeIdentifiers

struct AudioTrack: Identifiable, Equatable, Sendable {
    let url: URL
    let directory: String
    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var fileName: String { url.lastPathComponent }
}

struct AudioFolderGroup: Identifiable, Equatable, Sendable {
    let directory: String
    let title: String
    let tracks: [AudioTrack]
    var id: String { directory }
}

struct AudioLibraryScan: Sendable {
    let groups: [AudioFolderGroup]
    let unreadableFolders: Int
    var trackCount: Int { groups.reduce(0) { $0 + $1.tracks.count } }
}

enum AudioLibrary {
    // UTType covers macOS formats; additional audio extensions can still be listed even
    // if the system needs a codec to play them. Playback errors identify the selected file.
    private static let audioExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc", "mp3", "m4a", "aac", "caf", "flac", "alac", "ogg", "oga", "opus", "wma"
    ]
    static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .audio) == true
    }
    // Runs on a cancellable worker task. No decoding or metadata reads for every song.
    static func scan(_ folder: URL) throws -> AudioLibraryScan {
        try Task.checkCancellation()
        let root = folder.standardizedFileURL
        let resource = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard resource.isDirectory == true else { throw AudioFailure(message: "Choose a folder containing audio files.") }
        var unreadable = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in unreadable += 1; return true }
        ) else { throw AudioFailure(message: "Could not read this folder.") }
        var grouped: [String: [AudioTrack]] = [:]
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard isAudio(url) else { continue }
            guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            guard parent == root.path || parent.hasPrefix(prefix) else { continue }
            let directory = parent == root.path ? "" : String(parent.dropFirst(prefix.count))
            grouped[directory, default: []].append(AudioTrack(url: url, directory: directory))
        }
        let groups = grouped.keys.sorted { a, b in
            if a.isEmpty { return !b.isEmpty }
            if b.isEmpty { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { directory in
            AudioFolderGroup(directory: directory, title: directory.isEmpty ? root.lastPathComponent : directory,
                             tracks: grouped[directory]!.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending })
        }
        return AudioLibraryScan(groups: groups, unreadableFolders: unreadable)
    }
    static func filter(_ groups: [AudioFolderGroup], query: String) -> [AudioFolderGroup] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return groups }
        return groups.compactMap { group in
            let tracks = group.title.localizedCaseInsensitiveContains(text) ? group.tracks
                : group.tracks.filter { $0.fileName.localizedCaseInsensitiveContains(text) }
            return tracks.isEmpty ? nil : AudioFolderGroup(directory: group.directory, title: group.title, tracks: tracks)
        }
    }
}
