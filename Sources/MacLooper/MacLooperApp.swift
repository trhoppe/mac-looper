import SwiftUI
import Combine
import LooperCore
#if os(macOS)
import AppKit
#endif
import JamCore
import AM4RemoteKit

#if os(macOS)
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: LooperModel?
    var files: AudioFilePlayerModel?
    var library: SongLibraryModel?
    var remote: AM4RemoteSession?
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
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--drummer-check") { setbuf(stdout, nil) }
        if let index = CommandLine.arguments.firstIndex(of: "--audio-check"), CommandLine.arguments.count > index + 1 {
            do {
                let asset = try PlaybackAsset(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("PASS: decoded \(asset.duration) seconds at \(Int(asset.file.processingFormat.sampleRate)) Hz / \(asset.file.processingFormat.channelCount) channels")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--library-check"), CommandLine.arguments.count > index + 1 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                let value = try JustChordsLibrary(data: data)
                for song in value.songs { _ = ChordProDocument(source: song.chordPro, transpose: song.transposition) }
                print("PASS: \(value.songs.count) songs, \(value.playlists.count) playlists, \(value.tags.count) tags; exact JSON bytes preserved: \(data == value.originalData)")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--am4-resources-check") {
            // Standalone bundle check: no MIDI connection or hardware writes.
            print("PASS: AM4 resources: \(AM4AmpCatalog.shared.models.count) amps, \(AM4EffectsCatalog.shared.effects.count) effect editors, \(AM4AmpLibrary.shared.entries.count) amp library entries, \(AM4EffectsLibrary.shared.entries.count) effect library entries")
            exit(0)
        }
        if CommandLine.arguments.contains("--devices") {
            do {
                for d in try AudioDevices.list() {
                    print("\(d.name) | input \(d.inputs) | output \(d.outputs) | \(Int(d.rate)) Hz | \(d.uid)")
                }
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("Mac Jams") {
            ContentView(model: model, readiness: session.readiness, files: files, remote: session.remote, library: library).equatable()
                .preferredColorScheme(.dark)
                .task {
                    #if os(macOS)
                    delegate.model = model; delegate.files = files; delegate.library = library; delegate.remote = session.remote
                    #endif
                    #if DEBUG && os(macOS)
                    if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
                        if let folderIndex = CommandLine.arguments.firstIndex(of: "--audio-folder"), CommandLine.arguments.count > folderIndex + 1 {
                            files.openFolder(URL(fileURLWithPath: CommandLine.arguments[folderIndex + 1]))
                        }
                        if let songIndex = CommandLine.arguments.firstIndex(of: "--preview-song"), CommandLine.arguments.count > songIndex + 1 {
                            for _ in 0..<200 where library.library == nil { try? await Task.sleep(for: .milliseconds(20)) }
                            library.selectedSongID = library.library?.songs.first(where: { $0.title.localizedCaseInsensitiveCompare(CommandLine.arguments[songIndex + 1]) == .orderedSame })?.id
                        }
                        do {
                            try await AppPreview.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), files: files)
                            files.shutdown(); exit(0)
                        } catch { fputs("\(error.localizedDescription)\n", stderr); files.shutdown(); exit(1) }
                    }
                    #endif
                    if CommandLine.arguments.contains("--drummer-check") {
                        do { try await DrummerDiagnostics.run(); exit(0) }
                        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
                    }
                    if CommandLine.arguments.contains("--am4-check") {
                        do {
                            for line in try await AM4RemoteDiagnostics.run(session: session.remote, exerciseControls: CommandLine.arguments.contains("--am4-exercise-controls")) { print(line) }
                            session.remote.stop(); exit(0)
                        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); session.remote.stop(); exit(1) }
                    }
                    if CommandLine.arguments.contains("--smoke-test") {
                        print("Smoke: requesting loop audio")
                        await model.startAutomatically()
                        print("Smoke: loop audio returned running=\(model.running) error=\(model.error ?? "none")")
                        guard model.running else { print("FAIL: " + (model.error ?? "Audio did not start")); model.shutdown(); exit(1) }
                        let player = FilePlayback(), token = UUID()
                        var fileExpected = false
                        var restartContinued = true
                        let drumsExpected = CommandLine.arguments.contains("--smoke-drums")
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
                        if let index = CommandLine.arguments.firstIndex(of: "--smoke-file"), CommandLine.arguments.count > index + 1 {
                            fileExpected = true
                            do {
                                guard let output = model.output else { throw AudioFailure(message: "No output selected.") }
                                print("Smoke: loading file")
                                _ = try await player.load(URL(fileURLWithPath: CommandLine.arguments[index + 1]), session: token, volume: 0, repeating: true)
                                print("Smoke: playing file")
                                try await player.play(session: token, output: output)
                                print("Smoke: file play returned")
                                try await Task.sleep(for: .seconds(1))
                                await player.seek(session: token, to: 0)
                                let restarted = await player.snapshot(session: token)
                                restartContinued = restarted?.playing == true && (restarted?.position ?? 1) < 0.2
                            } catch { model.error = error.localizedDescription }
                        }
                        if CommandLine.arguments.contains("--smoke-am4") {
                            do {
                                for line in try await AM4RemoteDiagnostics.run(session: session.remote, exerciseControls: CommandLine.arguments.contains("--am4-exercise-controls")) { print("Smoke MIDI: " + line) }
                            } catch { model.error = error.localizedDescription }
                        }
                        let durationIndex = CommandLine.arguments.firstIndex(of: "--smoke-seconds")
                        let duration = durationIndex.flatMap { CommandLine.arguments.count > $0 + 1 ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 3
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
                    if NSClassFromString("XCTestCase") == nil && !CommandLine.arguments.contains("--editor-check-folder") {
                        await model.startAutomatically()
                        if CommandLine.arguments.contains("--open-drums") { await AudioEngineHost.shared.drums.openEditor() }
                    }

                }
        }
        #if os(macOS)
        .defaultSize(width: 1320, height: 860)
        .windowResizability(.contentMinSize)
        #endif
        .commands { JamCommands(session: session) }
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
        if let index = CommandLine.arguments.firstIndex(of: "--editor-check-folder"), CommandLine.arguments.count > index + 1 {
            // UI validation uses an isolated fixture and defaults, never user songs.
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            let io: LibraryFiles
            if CommandLine.arguments.contains("--simulate-library-conflict") {
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
        #if os(iOS)
        if NSClassFromString("XCTestCase") == nil { lifecycle = IPadAudioLifecycle(model: model, files: files) }
        #endif
    }
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
        CommandGroup(replacing: .newItem) { }
        CommandMenu("Backing Track") {
            Button("Restart Track") { session.files.restart() }
                .keyboardShortcut(.leftArrow, modifiers: []).disabled(!available.canRestart || available.editing || remote.isPresented)
        }
        CommandMenu("Loop") {
            Button("Arm") { Task { await session.model.arm() } }.keyboardShortcut("r", modifiers: []).disabled(!available.canArm || available.editing || remote.isPresented)
            Button("Play / Stop") { session.model.playStop() }.keyboardShortcut(.space, modifiers: []).disabled(!available.canPlay || available.editing || remote.isPresented)
            Button("Clear") { session.model.clear() }.keyboardShortcut(.delete, modifiers: []).disabled(!available.canClear || available.editing || remote.isPresented)
        }
    }
}
