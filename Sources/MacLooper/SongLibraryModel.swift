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
    @Published var editing = false {
        didSet { if !editing && refreshRequested { Task { await refresh() } } }
    }
    @Published private(set) var saving = false
    @Published private(set) var folderURL: URL
    @Published private(set) var syncing = false
    @Published private(set) var backingLinks: [String: String] = [:]
    private let io: LibraryFiles
    @Published private(set) var conflicts: [LibraryConflictCopy] = []
    private let readLibrary: ((URL) async throws -> JustChordsLibrary)?
    private let readTracks: ((URL) async throws -> [String: URL])?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var reading = false
    private var revision = 0
    private var access: [URL] = []
    private var lastBytes: Data?
    private var bookmarkStore: [String: Data] = [:]
    private let defaults: UserDefaults
    let recoveryStore: SongDraftRecoveryStore
    @Published private(set) var recoveredDrafts: [RecoveredSongDraft] = []
    private var draftSequence = Int(DispatchTime.now().uptimeNanoseconds)
    func nextDraftSequence() -> Int { draftSequence += 1; return draftSequence }
    func refreshRecoveredDrafts() async {
        let token = revision, destination = destination
        do {
            let drafts = try await recoveryStore.drafts(in: destination)
            guard revision == token else { return }
            recoveredDrafts = drafts
        } catch { if token == revision { self.error = "Couldn’t read recovered edits: " + error.localizedDescription } }
    }

    init(defaults: UserDefaults = .standard, loadOnLaunch: Bool = true, folderOverride: URL? = nil,
         readLibrary: ((URL) async throws -> JustChordsLibrary)? = nil,
         readTracks: ((URL) async throws -> [String: URL])? = nil,
         recoveryStore: SongDraftRecoveryStore? = nil, io: LibraryFiles = LibraryFiles()) {
        self.io = io
        self.recoveryStore = recoveryStore ?? SongDraftRecoveryStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacJams/Draft Recovery", isDirectory: true))
        self.defaults = defaults; self.readLibrary = readLibrary; self.readTracks = readTracks
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
        restoreBackingBookmarks()
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
        lastBytes = nil; library = nil; selectedSongID = nil; playlistID = nil
        backingLinks = [:]; bookmarkStore = [:]; restoreBackingBookmarks()
        recoveredDrafts = []; conflicts = []; error = nil; status = "Opening library…"
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
        refreshRequested = true
        if let refreshTask { await refreshTask.value; return }
        guard !saving && !editing else { return }
        let task = Task { await drainRefreshes(); refreshTask = nil }
        refreshTask = task
        await task.value
    }
    private func drainRefreshes() async {
        reading = true; syncing = true
        defer { reading = false; syncing = false }
        await refreshRecoveredDrafts()
        while refreshRequested && !saving && !editing && !Task.isCancelled {
            refreshRequested = false
            let token = revision, folder = folderURL, destination = destination
            do {
                let next: JustChordsLibrary
                if let readLibrary { next = try await readLibrary(destination) }
                else { next = try await io.prepareChordProLibrary(at: destination) }
                guard token == revision, !Task.isCancelled else { continue }
                let tracks: [String: URL]
                if let readTracks { tracks = (try? await readTracks(folder)) ?? [:] }
                else { tracks = (try? await io.backingTracks(in: folder)) ?? [:] }
                let versions = readLibrary == nil ? try await io.conflictCopies(at: destination) : []
                // Publish a complete snapshot only after both reads are current.
                guard token == revision, !Task.isCancelled else { continue }
                guard !editing && !saving else { refreshRequested = true; break }
                if lastBytes != next.originalData { library = next; lastBytes = next.originalData }
                backingLinks = bookmarkStore.compactMapValues { Self.resolve($0)?.path }
                for (id, url) in tracks { backingLinks[id] = url.path }
                conflicts = versions
                error = versions.isEmpty ? nil : SongEditError.unresolvedCloudConflict.localizedDescription
                status = "\(next.songs.count) songs · Mac Jams library"
                if let id = selectedSongID, !next.songs.contains(where: { $0.id == id }) { selectedSongID = nil }
            } catch {
                guard token == revision, !Task.isCancelled else { continue }
                self.error = error.localizedDescription
                status = library == nil ? "Choose your library folder in Settings" : "Using last good library · check its folder in Settings"
            }
        }
    }
    private var backingBookmarkKey: String { "backingBookmarks:" + folderURL.standardizedFileURL.path }
    private func restoreBackingBookmarks() {
        let data = defaults.data(forKey: backingBookmarkKey) ?? defaults.data(forKey: "backingBookmarks")
        if let data, let values = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            bookmarkStore = values.filter { _, data in
                Self.resolve(data)?.standardizedFileURL.path.hasPrefix(folderURL.standardizedFileURL.path + "/") == true
            }
        }
        backingLinks = bookmarkStore.compactMapValues { Self.resolve($0)?.path }
    }
    func save(_ draft: SongDraft) async throws {
        guard !reading && !saving else { throw SongEditError.validation("The library is busy. Try Save again in a moment.") }
        saving = true
        let token = revision, destination = destination
        defer {
            saving = false
            if refreshRequested && !editing { Task { await refresh() } }
        }
        do {
            let next = try await io.save(draft, to: destination)
            guard token == revision else { throw SongEditError.conflict }
            library = next; lastBytes = next.originalData; error = nil
            status = "\(next.songs.count) songs · saved to Mac Jams"
        } catch {
            self.error = error.localizedDescription
            if let copies = try? await io.conflictCopies(at: destination), token == revision { conflicts = copies }
            throw error
        }
    }
    func resolveConflict(using copy: LibraryConflictCopy) async throws {
        guard !reading && !saving && !editing else { throw SongEditError.validation("Finish editing before choosing a library version.") }
        saving = true
        let token = revision, destination = destination, expected = conflicts
        defer { saving = false }
        do {
            let next = try await io.resolveConflict(using: copy.id, expected: expected, at: destination)
            guard revision == token else { throw SongEditError.conflictsChanged }
            library = next; lastBytes = next.originalData; conflicts = []; error = nil
            if let id = selectedSongID, !next.songs.contains(where: { $0.id == id }) { selectedSongID = nil }
            status = "\(next.songs.count) songs · library conflict resolved"
        } catch { self.error = error.localizedDescription; throw error }
    }
    func openLibrary(_ url: URL) {
        guard url.lastPathComponent == "library.json" else { error = "Choose library.json from your Mac Jams library folder."; return }
        setFolder(url.deletingLastPathComponent())
    }
    func linkBacking(_ url: URL, songID: String) {
        retainAccess(url)
        status = "Copying backing track to Mac Jams…"
        let token = revision, folder = folderURL
        Task {
            do {
                let copied = try await io.attachBacking(url, songID: songID, in: folder)
                guard token == revision else { return }
                backingLinks[songID] = copied.path
                if let data = Self.bookmark(copied) {
                    bookmarkStore[songID] = data
                    if let encoded = try? PropertyListEncoder().encode(bookmarkStore) { defaults.set(encoded, forKey: backingBookmarkKey) }
                }
                status = "Backing saved with song · available in the library folder"
            } catch { if token == revision { self.error = error.localizedDescription } }
        }
    }
    func backingURL(songID: String) -> URL? {
        if let path = backingLinks[songID], path.hasPrefix(folderURL.path + "/") { return URL(fileURLWithPath: path) }
        if let data = bookmarkStore[songID], let url = Self.resolve(data) { retainAccess(url); return url }
        return backingLinks[songID].map { URL(fileURLWithPath: $0) }
    }
    func shutdown() { revision += 1; refreshTask?.cancel(); refreshRequested = false; for url in access { url.stopAccessingSecurityScopedResource() }; access = [] }
}
