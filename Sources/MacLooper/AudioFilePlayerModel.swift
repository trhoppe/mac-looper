import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor @Observable final class PlaybackTiming {
    var position = 0.0
    var duration = 0.0
}

@MainActor final class AudioFilePlayerModel: ObservableObject {
    @Published private(set) var groups: [AudioFolderGroup] = [] {
        didSet { tracks = groups.flatMap(\.tracks); updateSelectedIndex() }
    }
    private(set) var tracks: [AudioTrack] = []
    @Published private(set) var visibleGroups: [AudioFolderGroup] = []
    @Published private(set) var folder: URL?
    @Published private(set) var scanning = false
    @Published private(set) var hasDuration = false
    @Published private(set) var loading = false
    @Published private(set) var selected: AudioTrack? { didSet { updateSelectedIndex() } }
    private var selectedIndex: Int?
    private func updateSelectedIndex() {
        selectedIndex = selected.flatMap { track in tracks.firstIndex { $0.id == track.id } }
    }
    private(set) var duration: Double {
        get { timing.duration }
        set {
            timing.duration = newValue
            let available = newValue > 0
            if available != hasDuration { hasDuration = available }
        }
    }
    private(set) var position: Double {
        get { timing.position }
        set { timing.position = newValue }
    }
    @Published private(set) var playing = false
    @Published private(set) var startingPlayback = false
    private var playRequest = UUID()
    @Published var query = "" { didSet { visibleGroups = AudioLibrary.filter(groups, query: query) } }
    @Published var requestingFolder = false
    @Published var requestingFile = false
    @Published var error: String?
    @Published private(set) var scanNotice: String?
    @Published var volume = 1.0 { didSet { configure() } }
    @Published var repeatTrack = false { didSet { configure() } }
    private var output: AudioDevice?
    private let host: AudioEngineHost
    private let playback: FilePlayback
    private var session = UUID()
    private var scanGeneration = UUID()
    private var worker: Task<AudioLibraryScan, Error>?
    private var loadTask: Task<Void, Never>?
    private var timer: Timer?
    let timing = PlaybackTiming()
    private var scopedFolder: URL?
    private var scopedFile: URL?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, restoreFolder: Bool = true, host: AudioEngineHost? = nil) {
        let host = host ?? AudioEngineHost.shared
        self.host = host
        self.playback = FilePlayback(host: host)
        self.defaults = defaults
        if restoreFolder, let url = SongLibraryModel.resolve(defaults.data(forKey: "audioPlayerFolder")) {
            openFolder(url)
        }
    }
    var trackCount: Int { tracks.count }
    var outputName: String { output?.name ?? "Choose an output in settings" }
    func setOutput(_ device: AudioDevice?) {
        guard output?.uid != device?.uid else { output = device; return }
        pauseForInterruption()
        output = device
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
        pauseForInterruption()
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
    func selectFile(_ url: URL, autoplay: Bool = false) {
        guard url.isFileURL, AudioLibrary.isAudio(url) else {
            error = "Choose an audio file such as an MP3."
            return
        }
        let track = tracks.first { $0.url.standardizedFileURL == url.standardizedFileURL }
        select(AudioTrack(url: url, directory: track?.directory ?? url.deletingLastPathComponent().lastPathComponent), autoplay: autoplay)
    }
    func select(_ track: AudioTrack, autoplay: Bool = false) {
        guard autoplay || selected?.id != track.id else { return }
        pauseForInterruption()
        let autoplayRequest = playRequest
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
                if autoplay, playRequest == autoplayRequest { startPlayback() }
            } catch {
                guard session == token, !Task.isCancelled else { return }
                loading = false; self.error = "Cannot open \(track.fileName): \(error.localizedDescription)"
            }
        }
    }
    func togglePlay() {
        guard selected != nil, !loading, duration > 0 else { return }
        if playing || startingPlayback {
            pauseForInterruption()
        } else {
            startPlayback()
        }
    }
    private func startPlayback() {
        let token = session
        #if os(macOS)
        let device = output ?? AudioDevices.systemOutput()
        let useSystemBuffer = output == nil
        #else
        let device = output
        let useSystemBuffer = false
        #endif
        guard let device else { error = "Choose an output device in Audio Settings before playing a file."; return }
        guard let request = host.requestFilePlay(session: token) else { return }
        playRequest = request; startingPlayback = true; error = nil
        Task {
            do {
                guard session == token, playRequest == request else { return }
                try await playback.play(session: token, output: device, requestedIntent: request, useSystemBuffer: useSystemBuffer)
                guard session == token, playRequest == request else { return }
                startingPlayback = false
                poll()
            } catch {
                guard session == token, playRequest == request else { return }
                startingPlayback = false; playing = false; self.error = error.localizedDescription
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
        host.seekFile(session: token, to: 0); poll()
    }
    func pauseForInterruption() {
        playRequest = UUID(); startingPlayback = false; playing = false
        // Invalidate pending host Play immediately, before the actor hop.
        host.pauseFile(session: session)
        if let snapshot = host.fileSnapshot(session: session) { position = snapshot.position }
        stopPolling()
    }
    func stop() {
        pauseForInterruption()
        let token = session; playing = false; position = 0
        host.stopFile(session: token)
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0, !loading else { return }
        position = min(duration, max(0, seconds))
        let token = session
        host.seekFile(session: token, to: seconds)
    }
    func step(_ offset: Int) {
        let list = tracks
        guard let index = selectedIndex, list.indices.contains(index + offset) else { return }
        select(list[index + offset])
    }
    func canStep(_ offset: Int) -> Bool {
        guard let index = selectedIndex else { return false }
        return tracks.indices.contains(index + offset)
    }
    private func configure() {
        let token = session
        Task { await playback.configure(session: token, volume: Float(volume), repeating: repeatTrack) }
    }
    private func startPolling() {
        guard playing, timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
    private func poll() {
        guard selected != nil, !loading else { stopPolling(); return }
        let token = session
        if playing, let output, !host.fileOutputAvailable(output) {
            pauseForInterruption()
            playing = false; error = "The file-player output disconnected. Reconnect it or choose another output."
            return
        }
        guard let snapshot = host.fileSnapshot(session: token) else {
            playing = false; stopPolling(); return
        }
        if duration != snapshot.duration { duration = snapshot.duration }
        if position != snapshot.position { position = snapshot.position }
        // The transport stays active while a replacement graph has no playing node.
        if playing != snapshot.intendsToPlay { playing = snapshot.intendsToPlay }
        if snapshot.intendsToPlay { startPolling() } else { stopPolling() }
    }
    func shutdown() {
        pauseForInterruption()
        worker?.cancel(); loadTask?.cancel(); stopPolling()
        let scope = scopedFolder, fileScope = scopedFile; scopedFolder = nil; scopedFile = nil
        let token = session
        Task { await playback.unload(session: token); scope?.stopAccessingSecurityScopedResource(); fileScope?.stopAccessingSecurityScopedResource() }
    }
}
