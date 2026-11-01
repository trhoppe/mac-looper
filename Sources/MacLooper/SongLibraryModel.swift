import Foundation
import SwiftUI
import JamCore

@MainActor final class SongLibraryModel: ObservableObject {
    @Published private(set) var library: JustChordsLibrary?
    @Published var selectedSongID: String?
    @Published var playlistID: String?
    @Published var query = ""
    @Published private(set) var status = "Choose your library in Settings"
    @Published private(set) var error: String?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var folderURL: URL
    @Published private(set) var syncing = false
    @Published private(set) var backingLinks: [String: String] = [:]
    private let io = LibraryFiles()
    private var reading = false
    private var revision = 0
    private var access: [URL] = []
    private var lastBytes: Data?
    private var bookmarkStore: [String: Data] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, loadOnLaunch: Bool = true) {
        self.defaults = defaults
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let own = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Mac Looper", isDirectory: true)
        folderURL = Self.resolve(defaults.data(forKey: "libraryFolder")) ?? own
        let justChords = home.appendingPathComponent("Library/Mobile Documents/iCloud~online~justchords~JustChords/Documents/library.json")
        sourceURL = Self.resolve(defaults.data(forKey: "librarySource")) ?? (FileManager.default.fileExists(atPath: justChords.path) ? justChords : nil)
        #else
        folderURL = Self.resolve(defaults.data(forKey: "libraryFolder")) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Library", isDirectory: true)
        sourceURL = Self.resolve(defaults.data(forKey: "librarySource"))
        #endif
        for url in [folderURL, sourceURL].compactMap({ $0 }) { if url.startAccessingSecurityScopedResource() { access.append(url) } }
        if let data = defaults.data(forKey: "backingBookmarks"), let values = try? PropertyListDecoder().decode([String: Data].self, from: data) { bookmarkStore = values }
        for (id, data) in bookmarkStore { if let url = Self.resolve(data) { backingLinks[id] = url.path } }
        if loadOnLaunch { Task { await refresh() } }
    }
    var selectedSong: LibrarySong? { songs.first(where: { $0.id == selectedSongID }) ?? library?.songs.first(where: { $0.id == selectedSongID }) }
    var songs: [LibrarySong] {
        (library?.songs(in: playlistID) ?? []).filter { song in
            query.isEmpty || song.title.localizedCaseInsensitiveContains(query) || song.artist.localizedCaseInsensitiveContains(query)
        }
    }
    var destination: URL { folderURL.appendingPathComponent("library.json") }
    func setSource(_ url: URL) {
        guard url.standardizedFileURL != destination.standardizedFileURL else {
            error = "This is already Mac Looper’s library. Choose the JustChords source to enable automatic refresh."; return
        }
        revision += 1; sourceURL = url
        retainAccess(url); saveBookmark(url, key: "librarySource")
        Task { await refresh() }
    }
    func setFolder(_ url: URL) {
        let next = url.appendingPathComponent("library.json")
        guard next.standardizedFileURL != sourceURL?.standardizedFileURL else { error = LibraryError.sameSourceAndDestination.localizedDescription; return }
        revision += 1; folderURL = url
        retainAccess(url); saveBookmark(url, key: "libraryFolder")
        lastBytes = nil
        Task { await refresh() }
    }
    private func retainAccess(_ url: URL) { if url.startAccessingSecurityScopedResource() { access.append(url) } }
    private func saveBookmark(_ url: URL, key: String) { if let data = Self.bookmark(url) { defaults.set(data, forKey: key) } }
    static func bookmark(_ url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    static func resolve(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        #if os(macOS)
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
    }
    func refresh() async {
        guard !reading else { return }
        reading = true; syncing = true
        let token = revision, source = sourceURL, destination = destination
        defer { reading = false; syncing = false }
        do {
            let next: JustChordsLibrary
            if let source {
                do {
                    next = try await io.read(source)
                    try await io.mirror(next, to: destination, source: source)
                } catch {
                    if library == nil, let cached = try? await io.read(destination) { library = cached; lastBytes = cached.originalData }
                    throw error
                }
            } else { next = try await io.read(destination) }
            guard token == revision else { return }
            if lastBytes != next.originalData { library = next; lastBytes = next.originalData }
            if let tracks = try? await io.backingTracks(in: folderURL) {
                for (id, url) in tracks { backingLinks[id] = url.path }
            }
            error = nil
            status = source == nil ? "\(next.songs.count) songs · library up to date" : "\(next.songs.count) songs · synced from JustChords"
            if let id = selectedSongID, !next.songs.contains(where: { $0.id == id }) { selectedSongID = nil }
        } catch {
            guard token == revision else { return }
            self.error = error.localizedDescription
            status = library == nil ? "Choose library.json or its iCloud folder in Settings" : "Using last good library · check source in Settings"
        }
    }
    func linkBacking(_ url: URL, songID: String) {
        retainAccess(url)
        status = "Copying backing track to Mac Looper…"
        Task {
            do {
                let copied = try await io.attachBacking(url, songID: songID, in: folderURL)
                backingLinks[songID] = copied.path
                if let data = Self.bookmark(copied) {
                    bookmarkStore[songID] = data
                    if let encoded = try? PropertyListEncoder().encode(bookmarkStore) { defaults.set(encoded, forKey: "backingBookmarks") }
                }
                status = "Backing saved with song · available in Mac Looper’s folder"
            } catch { self.error = error.localizedDescription }
        }
    }
    func backingURL(songID: String) -> URL? {
        if let path = backingLinks[songID], path.hasPrefix(folderURL.path + "/") { return URL(fileURLWithPath: path) }
        if let data = bookmarkStore[songID], let url = Self.resolve(data) { retainAccess(url); return url }
        return backingLinks[songID].map { URL(fileURLWithPath: $0) }
    }
    func shutdown() { for url in access { url.stopAccessingSecurityScopedResource() }; access = [] }
}
