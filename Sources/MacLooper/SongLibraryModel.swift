import Foundation
import SwiftUI
import JamCore

@MainActor final class SongLibraryModel: ObservableObject {
    @Published private(set) var library: JustChordsLibrary?
    @Published var selectedSongID: String?
    @Published var playlistID: String?
    @Published var query = ""
    @Published var sortOrder: SongSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: "songSortOrder") }
    }
    @Published private(set) var status = "Choose your library in Settings"
    @Published private(set) var error: String?
    @Published var editing = false
    @Published private(set) var saving = false
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

    init(defaults: UserDefaults = .standard, loadOnLaunch: Bool = true, folderOverride: URL? = nil) {
        self.defaults = defaults
        sortOrder = SongSortOrder(rawValue: defaults.string(forKey: "songSortOrder") ?? "") ?? .songName
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let own = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Mac Looper", isDirectory: true)
        folderURL = folderOverride ?? Self.resolve(defaults.data(forKey: "libraryFolder")) ?? own
        #else
        folderURL = folderOverride ?? Self.resolve(defaults.data(forKey: "libraryFolder")) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Library", isDirectory: true)
        #endif
        // The existing own copy is authoritative. A legacy source bookmark must
        // never trigger another JustChords import after native editing is enabled.
        defaults.removeObject(forKey: "librarySource")
        retainAccess(folderURL)
        if let data = defaults.data(forKey: "backingBookmarks"), let values = try? PropertyListDecoder().decode([String: Data].self, from: data) { bookmarkStore = values }
        for (id, data) in bookmarkStore { if let url = Self.resolve(data) { backingLinks[id] = url.path } }
        if loadOnLaunch { Task { await refresh() } }
    }
    var selectedSong: LibrarySong? { songs.first(where: { $0.id == selectedSongID }) ?? library?.songs.first(where: { $0.id == selectedSongID }) }
    var songs: [LibrarySong] {
        sortOrder.apply(to: library?.songs(in: playlistID) ?? [], query: query)
    }

    var destination: URL { folderURL.appendingPathComponent("library.json") }
    func setFolder(_ url: URL) {
        let next = url.appendingPathComponent("library.json")
        guard !editing && !saving else { error = "Finish editing this song before changing libraries."; return }
        guard !LibraryFiles.isProtectedLibrary(next) else { error = SongEditError.protectedLibrary.localizedDescription; return }
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
        guard !reading && !saving && !editing else { return }
        reading = true; syncing = true
        let token = revision, destination = destination
        defer { reading = false; syncing = false }
        do {
            let next = try await io.read(destination)
            guard token == revision else { return }
            if lastBytes != next.originalData { library = next; lastBytes = next.originalData }
            if let tracks = try? await io.backingTracks(in: folderURL) {
                for (id, url) in tracks { backingLinks[id] = url.path }
            }
            error = nil
            status = "\(next.songs.count) songs · Mac Jams library"
            if let id = selectedSongID, !next.songs.contains(where: { $0.id == id }) { selectedSongID = nil }
        } catch {
            guard token == revision else { return }
            self.error = error.localizedDescription
            status = library == nil ? "Choose your library folder in Settings" : "Using last good library · check its folder in Settings"
        }
    }
    func save(_ draft: SongDraft) async throws {
        guard !reading && !saving else { throw SongEditError.validation("The library is busy. Try Save again in a moment.") }
        saving = true
        let token = revision, destination = destination
        defer { saving = false }
        do {
            let next = try await io.save(draft, to: destination)
            guard token == revision else { throw SongEditError.conflict }
            library = next; lastBytes = next.originalData; error = nil
            status = "\(next.songs.count) songs · saved to Mac Jams"
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
    func openLibrary(_ url: URL) {
        guard url.lastPathComponent == "library.json" else { error = "Choose library.json from your Mac Jams library folder."; return }
        setFolder(url.deletingLastPathComponent())
    }
    func linkBacking(_ url: URL, songID: String) {
        retainAccess(url)
        status = "Copying backing track to Mac Jams…"
        Task {
            do {
                let copied = try await io.attachBacking(url, songID: songID, in: folderURL)
                backingLinks[songID] = copied.path
                if let data = Self.bookmark(copied) {
                    bookmarkStore[songID] = data
                    if let encoded = try? PropertyListEncoder().encode(bookmarkStore) { defaults.set(encoded, forKey: "backingBookmarks") }
                }
                status = "Backing saved with song · available in the library folder"
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
