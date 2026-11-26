import SwiftUI
import Combine
import LooperCore
#if DEBUG && targetEnvironment(simulator)
import AVFoundation
#endif
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif
import JamCore
import AM4RemoteKit

enum LaunchOptions {
    private static let parsed: (flags: Set<String>, values: [String: String]) = {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var values: [String: String] = [:]
        for (flag, value) in zip(arguments, arguments.dropFirst())
            where flag.hasPrefix("--") && values[flag] == nil {
            values[flag] = value
        }
        return (Set(arguments), values)
    }()
    static func has(_ flag: String) -> Bool { parsed.flags.contains(flag) }
    static func value(_ flag: String) -> String? { parsed.values[flag] }
}

#if os(macOS)
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: LooperModel?
    var files: AudioFilePlayerModel? {
        didSet {
            guard files != nil, !pendingOpenURLs.isEmpty else { return }
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            open(urls)
        }
    }
    var library: SongLibraryModel?
    var remote: AM4RemoteSession?
    private var pendingOpenURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) { open(urls) }

    private func open(_ urls: [URL]) {
        guard let files else {
            // Finder can send an open event before the first window is ready.
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        let localURLs = urls.filter(\.isFileURL)
        if let url = localURLs.first(where: { $0.pathExtension.lowercased() == "jamloop" }) {
            Task { await model?.openLoop(url) }
        }
        for url in localURLs where url.pathExtension.lowercased() == "json" { library?.openLibrary(url) }
        if let url = localURLs.first(where: AudioLibrary.isAudio) { files.selectFile(url, autoplay: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { remote?.stop(); model?.shutdown(); files?.shutdown(); library?.shutdown() }
}

#endif

@main @MainActor struct MacLooperApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    // Own models without subscribing the App/Scene to audio meters or file position.
    @StateObject private var session = JamSession()
    private var model: LooperModel { session.model }
    private var files: AudioFilePlayerModel { session.files }
    private var library: SongLibraryModel { session.library }
    init() {
        if LaunchOptions.has("--smoke-test") || LaunchOptions.has("--drummer-check") { setbuf(stdout, nil) }
        if let audioPath = LaunchOptions.value("--audio-check") {
            do {
                let asset = try PlaybackAsset(URL(fileURLWithPath: audioPath))
                print("PASS: decoded \(asset.duration) seconds at \(Int(asset.file.processingFormat.sampleRate)) Hz / \(asset.file.processingFormat.channelCount) channels")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let libraryPath = LaunchOptions.value("--library-check") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: libraryPath))
                let value = try JustChordsLibrary(data: data)
                for song in value.songs { _ = ChordProDocument(source: song.chordPro, transpose: song.transposition) }
                print("PASS: \(value.songs.count) songs, \(value.playlists.count) playlists, \(value.tags.count) tags; exact JSON bytes preserved: \(data == value.originalData)")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if LaunchOptions.has("--am4-resources-check") {
            // Standalone bundle check: no MIDI connection or hardware writes.
            print("PASS: AM4 resources: \(AM4AmpCatalog.shared.models.count) amps, \(AM4EffectsCatalog.shared.effects.count) effect editors, \(AM4AmpLibrary.shared.entries.count) amp library entries, \(AM4EffectsLibrary.shared.entries.count) effect library entries")
            exit(0)
        }
        if LaunchOptions.has("--devices") {
            do {
                for d in try AudioDevices.list() {
                    print("\(d.name) | input \(d.inputs) | output \(d.outputs) | \(Int(d.rate)) Hz | \(d.uid)")
                }
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        mainWindow {
            ContentView(model: model, readiness: session.readiness, files: files, remote: session.remote, library: library).equatable()
                .buttonStyle(JamButtonStyle())
                .preferredColorScheme(.dark)
                .task {
                    #if os(macOS)
                    delegate.model = model; delegate.library = library; delegate.remote = session.remote; delegate.files = files
                    #endif
                    #if DEBUG && os(macOS)
                    if let previewPath = LaunchOptions.value("--render-preview") {
                        if let folderPath = LaunchOptions.value("--audio-folder") {
                            files.openFolder(URL(fileURLWithPath: folderPath))
                        }
                        if let songTitle = LaunchOptions.value("--preview-song") {
                            for _ in 0..<200 where library.library == nil { try? await Task.sleep(for: .milliseconds(20)) }
                            library.selectedSongID = library.library?.songs.first(where: { $0.title.localizedCaseInsensitiveCompare(songTitle) == .orderedSame })?.id
                        }
                        do {
                            try await AppPreview.write(to: URL(fileURLWithPath: previewPath), files: files)
                            files.shutdown(); exit(0)
                        } catch { fputs("\(error.localizedDescription)\n", stderr); files.shutdown(); exit(1) }
                    }
                    #endif
                    if LaunchOptions.has("--drummer-check") {
                        do { try await DrummerDiagnostics.run(); exit(0) }
                        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
                    }
                    if LaunchOptions.has("--am4-check") {
                        do {
                            for line in try await AM4RemoteDiagnostics.run(session: session.remote, exerciseControls: LaunchOptions.has("--am4-exercise-controls")) { print(line) }
                            session.remote.stop(); exit(0)
                        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); session.remote.stop(); exit(1) }
                    }
                    if LaunchOptions.has("--smoke-test") {
                        print("Smoke: requesting loop audio")
                        await model.startAutomatically()
                        print("Smoke: loop audio returned running=\(model.running) error=\(model.error ?? "none")")
                        guard model.running else { print("FAIL: " + (model.error ?? "Audio did not start")); model.shutdown(); exit(1) }
                        let player = FilePlayback(), token = UUID()
                        var fileExpected = false
                        var restartContinued = true
                        let drumsExpected = LaunchOptions.has("--smoke-drums")
                        let drums = AudioEngineHost.shared.drums
                        var drumVerified = !drumsExpected
                        if drumsExpected {
                            drums.volume = 0
                            await drums.toggle(output: model.output)
                            let before = drums.transport.transportQueries
                            try? await Task.sleep(for: .seconds(1))
                            let firstBeat = drums.transport.beatPosition
                            drums.tempo = 90
                            try? await Task.sleep(for: .seconds(1))
                            let secondBeat = drums.transport.beatPosition
                            drumVerified = drums.playing && firstBeat > 1 && secondBeat > firstBeat + 1 && secondBeat < firstBeat + 2.5 && drums.transport.renderedFrames == 32 && drums.transport.transportQueries > before + 500
                            print("Smoke: muted drums follow 120 → 90 BPM: \(drumVerified); plugin error=\(drums.error ?? "none")")
                        }
                        if let audioPath = LaunchOptions.value("--smoke-file") {
                            fileExpected = true
                            do {
                                guard let output = model.output else { throw AudioFailure(message: "No output selected.") }
                                print("Smoke: loading file")
                                _ = try await player.load(URL(fileURLWithPath: audioPath), session: token, volume: 0, repeating: true)
                                print("Smoke: playing file")
                                try await player.play(session: token, output: output)
                                print("Smoke: file play returned")
                                try await Task.sleep(for: .seconds(1))
                                await player.seek(session: token, to: 0)
                                let restarted = await player.snapshot(session: token)
                                restartContinued = restarted?.playing == true && (restarted?.position ?? 1) < 0.2
                            } catch { model.error = error.localizedDescription }
                        }
                        if LaunchOptions.has("--smoke-am4") {
                            do {
                                for line in try await AM4RemoteDiagnostics.run(session: session.remote, exerciseControls: LaunchOptions.has("--am4-exercise-controls")) { print("Smoke MIDI: " + line) }
                            } catch { model.error = error.localizedDescription }
                        }
                        let duration = LaunchOptions.value("--smoke-seconds").flatMap(Double.init) ?? 3
                        try? await Task.sleep(for: .seconds(duration.isFinite ? min(120, max(3, duration)) : 3))
                        let file = await player.snapshot(session: token)
                        if drumsExpected {
                            drumVerified = drumVerified && drums.playing && drums.transport.renderedFrames == 32
                            drums.setPlaying(false); AudioEngineHost.shared.updateDrummerVolume()
                            let stoppedBeat = drums.transport.beatPosition
                            try? await Task.sleep(for: .milliseconds(100))
                            drumVerified = drumVerified && abs(drums.transport.beatPosition - stoppedBeat) < 0.01
                            print("Smoke: simultaneous backing + muted drums + guitar input, then drum Stop: \(drumVerified)")
                        }
                        let success = drumVerified && restartContinued && library.selectedSongID == nil && model.running && model.error == nil && model.audioCallbackCount > 100 && model.audioCallbackFrames == 32
                            && (!fileExpected || (file?.playing == true && (file?.position ?? 0) > 0.1))
                        print(success ? "PASS: \(model.input?.name ?? "Input") input → \(model.output?.name ?? "Output") output at \(Int(model.sampleRate)) Hz; \(model.audioCallbackFrames) samples; \(model.audioCallbackCount) callbacks; concurrent silent file playback: \(fileExpected); restart kept playback: \(restartContinued); no chart selected; no live monitoring." : "FAIL: \(model.error ?? "Audio stopped or callbacks did not advance")")
                        await player.unload()
                        model.shutdown(); session.remote.stop()
                        exit(success ? 0 : 1)
                    }
                    // Hosted unit tests exercise DSP without opening physical I/O.
                    if NSClassFromString("XCTestCase") == nil && !LaunchOptions.has("--editor-check-folder") {
                        await model.startAutomatically()
                        if LaunchOptions.has("--open-drums") { await AudioEngineHost.shared.drums.openEditor() }
                    }

                }
        }
        .commands { JamCommands(session: session) }
    }

    @SceneBuilder private func mainWindow<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some Scene {
        #if os(macOS)
        // Finder opens another track in the existing player window.
        Window("Mac Jams", id: "main", content: content)
            .defaultSize(width: 1320, height: 860)
            .windowResizability(.contentMinSize)
        #else
        WindowGroup("Mac Jams", makeContent: content)
        #endif
    }
}

@MainActor private final class JamSession: ObservableObject {
    let model = LooperModel()
    let remote = AM4RemoteSession()
    let files = AudioFilePlayerModel()
    let library: SongLibraryModel
    let commands: JamCommandAvailability
    let readiness: AppReadinessModel
    #if os(iOS)
    private var lifecycle: IPadAudioLifecycle?
    #endif
    init() {
        #if DEBUG && targetEnvironment(simulator)
        let fixturePath = Self.phoneTestLibraryPath()
        #else
        let fixturePath: String? = nil
        #endif
        if let folderPath = LaunchOptions.value("--editor-check-folder") ?? fixturePath {
            // UI validation uses an isolated fixture and defaults, never user songs.
            let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
            let io: LibraryFiles
            if LaunchOptions.has("--simulate-library-conflict") {
                // Opt-in UI fixture, confined to the explicitly supplied test folder.
                // This does not create/resolve actual iCloud file versions.
                var resolved = false
                io = LibraryFiles(conflictVersions: { _ in
                    if resolved { return [] }
                    return [LibraryConflictVersion(id: "fixture", data: try Data(contentsOf: folder.appendingPathComponent("conflicting-library.json")),
                                                   date: Date(timeIntervalSince1970: 1793656800), device: "Test iPad")]
                }, markConflictResolved: { _, _ in resolved = true })
            } else { io = LibraryFiles() }
            library = SongLibraryModel(defaults: UserDefaults(suiteName: "MacJamsEditor-" + UUID().uuidString)!,
                                       folderOverride: folder,
                                       recoveryStore: SongDraftRecoveryStore(folder: folder.appendingPathComponent("Draft Recovery")), io: io)
        } else { library = SongLibraryModel() }
        commands = JamCommandAvailability(model: model, files: files, library: library)
        readiness = AppReadinessModel(audio: model, drums: AudioEngineHost.shared.drums, files: files, library: library)
        if NSClassFromString("XCTestCase") == nil {
            model.midi.start { [weak model] action in
                guard let model, model.acceptsMIDI else { return }
                switch action {
                case .arm: await model.arm()
                case .record: await model.record()
                case .playStop: model.playStop()
                case .clear: model.clear()
                case .drummer: await AudioEngineHost.shared.drums.toggle(output: model.output)
                }
            }
        }
        #if os(iOS)
        if NSClassFromString("XCTestCase") == nil { lifecycle = IPadAudioLifecycle(model: model, files: files) }
        #endif
    }
    #if DEBUG && targetEnvironment(simulator)
    private static func phoneTestLibraryPath() -> String? {
        guard let json = LaunchOptions.value("--phone-test-library") else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appendingPathComponent("library.json"))
            if LaunchOptions.has("--phone-test-jam-media") {
                let loops = LoopFiles.folder(in: folder)
                let tracks = folder.appendingPathComponent("Backing Tracks/01234567-890A-4BCD-8EF0-123456789ABC", isDirectory: true)
                try FileManager.default.createDirectory(at: loops, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
                let silence = [Float](repeating: 0, count: 4096)
                let loop = try SavedLoop(sampleRate: 48_000, bpm: 96, bars: 1, left: silence, right: silence)
                try loop.encoded().write(to: loops.appendingPathComponent("Practice Take.jamloop"))
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                buffer.frameLength = 4096
                for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 4096) }
                let file = try AVAudioFile(forWriting: tracks.appendingPathComponent("Example Track.caf"), settings: format.settings)
                try file.write(from: buffer)
            }
            return folder.path
        } catch {
            return nil
        }
    }
    #endif

}

@MainActor private final class JamCommandAvailability: ObservableObject {
    @Published var canArm = false
    @Published var canPlay = false
    @Published var canClear = false
    @Published var canRestart = false
    @Published var editing = false
    init(model: LooperModel, files: AudioFilePlayerModel, library: SongLibraryModel) {
        library.$editing.removeDuplicates().assign(to: &$editing)
        Publishers.CombineLatest(model.$state, model.$starting)
            .map { $0 == TL_EMPTY && !$1 }.removeDuplicates().assign(to: &$canArm)
        model.$state.map { $0 != TL_EMPTY }.removeDuplicates().assign(to: &$canPlay)
        Publishers.CombineLatest(model.$running, model.$state)
            .map { $0 && $1 != TL_EMPTY }.removeDuplicates().assign(to: &$canClear)
        Publishers.CombineLatest(files.$playing, files.$loading)
            .map { $0 && !$1 }.removeDuplicates().assign(to: &$canRestart)
    }
}

@MainActor private struct JamCommands: Commands {
    let session: JamSession
    @ObservedObject private var available: JamCommandAvailability
    @ObservedObject private var remote: AM4RemoteSession
    init(session: JamSession) { self.session = session; available = session.commands; remote = session.remote }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Audio File…") { session.files.requestingFile = true }
                .keyboardShortcut("o").disabled(available.editing || remote.isPresented)
        }
        CommandMenu("Backing Track") {
            Button("Restart Track") { session.files.restart() }
                .keyboardShortcut(.leftArrow, modifiers: []).disabled(!available.canRestart || available.editing || remote.isPresented)
            #if os(macOS)
            Divider()
            Button("Make Mac Jams the Default MP3 Player") {
                Task {
                    do {
                        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .mp3)
                    } catch {
                        let alert = NSAlert(error: error)
                        alert.messageText = "Couldn’t set Mac Jams as the default MP3 player"
                        alert.runModal()
                    }
                }
            }
            #endif
        }
        CommandMenu("Loop") {
            Button("Arm") { Task { await session.model.arm() } }.keyboardShortcut("r", modifiers: []).disabled(!available.canArm || available.editing || remote.isPresented)
            Button("Play / Stop") { session.model.playStop() }.keyboardShortcut(.space, modifiers: []).disabled(!available.canPlay || available.editing || remote.isPresented)
            Button("Clear") { session.model.clear() }.keyboardShortcut(.delete, modifiers: []).disabled(!available.canClear || available.editing || remote.isPresented)
        }
    }
}
