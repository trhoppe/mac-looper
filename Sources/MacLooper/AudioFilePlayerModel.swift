import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor final class AudioFilePlayerModel: ObservableObject {
    @Published private(set) var groups: [AudioFolderGroup] = []
    @Published private(set) var visibleGroups: [AudioFolderGroup] = []
    @Published private(set) var folder: URL?
    @Published private(set) var scanning = false
    @Published private(set) var loading = false
    @Published private(set) var selected: AudioTrack?
    @Published private(set) var duration = 0.0
    @Published private(set) var position = 0.0
    @Published private(set) var playing = false
    @Published var query = "" { didSet { visibleGroups = AudioLibrary.filter(groups, query: query) } }
    @Published var requestingFolder = false
    @Published var error: String?
    @Published private(set) var scanNotice: String?
    @Published var volume = 1.0 { didSet { configure() } }
    @Published var repeatTrack = false { didSet { configure() } }
    private var output: AudioDevice?
    private let playback = FilePlayback()
    private var session = UUID()
    private var scanGeneration = UUID()
    private var worker: Task<AudioLibraryScan, Error>?
    private var loadTask: Task<Void, Never>?
    private var timer: Timer?
    private var polling = false
    private var scopedFolder: URL?
    private var scopedFile: URL?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, restoreFolder: Bool = true) {
        self.defaults = defaults
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        if restoreFolder, let url = SongLibraryModel.resolve(defaults.data(forKey: "audioPlayerFolder")) {
            openFolder(url)
        }
    }
    var trackCount: Int { groups.reduce(0) { $0 + $1.tracks.count } }
    var tracks: [AudioTrack] { groups.flatMap(\.tracks) }
    var outputName: String { output?.name ?? "Choose an output in settings" }
    func setOutput(_ device: AudioDevice?) {
        guard output?.uid != device?.uid else { output = device; return }
        output = device; playing = false
        let token = session
        Task { await playback.pause(session: token) }
    }
    func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Open an audio folder"
        panel.message = "Audio files in this folder and its subfolders will appear in the browser."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.openFolder(url) }
        }
        #else
        requestingFolder = true
        #endif
    }
    func openFolder(_ url: URL) {
        worker?.cancel(); loadTask?.cancel()
        scanGeneration = UUID(); let generation = scanGeneration
        let previousSession = session
        session = UUID(); selected = nil; loading = false; playing = false; position = 0; duration = 0
        let previousScope = scopedFolder, previousFileScope = scopedFile
        scopedFile = nil
        scopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
        Task { await playback.unload(session: previousSession); previousScope?.stopAccessingSecurityScopedResource(); previousFileScope?.stopAccessingSecurityScopedResource() }
        folder = url; groups = []; visibleGroups = []; scanning = true; error = nil; scanNotice = nil
        if let bookmark = SongLibraryModel.bookmark(url) { defaults.set(bookmark, forKey: "audioPlayerFolder") }
        let task = Task.detached(priority: .userInitiated) { try AudioLibrary.scan(url) }
        worker = task
        Task {
            do {
                let result = try await task.value
                guard scanGeneration == generation else { return }
                groups = result.groups; visibleGroups = AudioLibrary.filter(groups, query: query)
                if result.unreadableFolders > 0 { scanNotice = "Skipped \(result.unreadableFolders) unreadable folders." }
            } catch is CancellationError { }
            catch { if scanGeneration == generation { self.error = error.localizedDescription } }
            if scanGeneration == generation { scanning = false; worker = nil }
        }
    }
    func selectFile(_ url: URL) {
        select(AudioTrack(url: url, directory: ""))
    }
    func select(_ track: AudioTrack) {
        guard selected?.id != track.id else { return }
        loadTask?.cancel()
        let previousScope = scopedFile
        scopedFile = track.url.startAccessingSecurityScopedResource() ? track.url : nil
        session = UUID(); let token = session
        selected = track; loading = true; playing = false; duration = 0; position = 0; error = nil
        loadTask = Task {
            defer { previousScope?.stopAccessingSecurityScopedResource() }
            do {
                let result = try await playback.load(track.url, session: token, volume: Float(volume), repeating: repeatTrack)
                guard session == token, !Task.isCancelled else { return }
                duration = result.duration; loading = false
            } catch {
                guard session == token, !Task.isCancelled else { return }
                loading = false; self.error = "Cannot open \(track.fileName): \(error.localizedDescription)"
            }
        }
    }
    func togglePlay() {
        guard selected != nil, !loading, duration > 0 else { return }
        let token = session
        if playing {
            playing = false
            Task { await playback.pause(session: token) }
        } else {
            guard let output else { error = "Choose an output device in Audio Settings before playing a file."; return }
            Task {
                do {
                    try await playback.play(session: token, output: output)
                    guard session == token else { return }
                    await poll()
                } catch { if session == token { playing = false; self.error = error.localizedDescription } }
            }
        }
    }
    func skip(_ seconds: Double) {
        guard seconds.isFinite, selected != nil, !loading, duration > 0 else { return }
        seek(position + seconds)
    }
    func restart() {
        guard selected != nil, !loading, duration > 0 else { return }
        position = 0
        let token = session
        Task { await playback.seek(session: token, to: 0); await poll() }
    }
    func stop() {
        let token = session; playing = false; position = 0
        Task { await playback.stop(session: token) }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0, !loading else { return }
        position = min(duration, max(0, seconds))
        let token = session
        Task { await playback.seek(session: token, to: seconds) }
    }
    func step(_ offset: Int) {
        let list = tracks
        guard let selected, let index = list.firstIndex(where: { $0.id == selected.id }), list.indices.contains(index + offset) else { return }
        select(list[index + offset])
    }
    func canStep(_ offset: Int) -> Bool {
        guard let selected, let index = tracks.firstIndex(where: { $0.id == selected.id }) else { return false }
        return tracks.indices.contains(index + offset)
    }
    private func configure() {
        let token = session
        Task { await playback.configure(session: token, volume: Float(volume), repeating: repeatTrack) }
    }
    private func poll() async {
        guard !polling, selected != nil, !loading else { return }
        polling = true; defer { polling = false }
        let token = session
        if playing, let output, !AudioDevices.alive(output.id) {
            await playback.pause(session: token)
            guard session == token else { return }
            playing = false; error = "The file-player output disconnected. Reconnect it or choose another output."
            return
        }
        guard let snapshot = await playback.snapshot(session: token), token == session else { return }
        if duration != snapshot.duration { duration = snapshot.duration }
        if position != snapshot.position { position = snapshot.position }
        if playing != snapshot.playing { playing = snapshot.playing }
    }
    func shutdown() {
        worker?.cancel(); loadTask?.cancel(); timer?.invalidate()
        let scope = scopedFolder, fileScope = scopedFile; scopedFolder = nil; scopedFile = nil
        let token = session
        Task { await playback.unload(session: token); scope?.stopAccessingSecurityScopedResource(); fileScope?.stopAccessingSecurityScopedResource() }
    }
}
