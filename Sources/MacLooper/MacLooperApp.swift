import SwiftUI
#if os(macOS)
import AppKit
#endif
import JamCore

#if os(macOS)
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: LooperModel?
    var files: AudioFilePlayerModel?
    var library: SongLibraryModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown(); files?.shutdown(); library?.shutdown() }
}

#endif

@main @MainActor struct MacLooperApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    @StateObject private var model = LooperModel()
    @StateObject private var files = AudioFilePlayerModel()
    @StateObject private var library = SongLibraryModel()
    init() {
        if CommandLine.arguments.contains("--smoke-test") { setbuf(stdout, nil) }
        if let index = CommandLine.arguments.firstIndex(of: "--library-check"), CommandLine.arguments.count > index + 1 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                let value = try JustChordsLibrary(data: data)
                for song in value.songs { _ = ChordProDocument(source: song.chordPro, transpose: song.transposition) }
                print("PASS: \(value.songs.count) songs, \(value.playlists.count) playlists, \(value.tags.count) tags; exact JSON bytes preserved: \(data == value.originalData)")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
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
        WindowGroup("Mac Looper") {
            ContentView(model: model, files: files, library: library)
                .preferredColorScheme(.dark)
                .task {
                    #if os(macOS)
                    delegate.model = model; delegate.files = files; delegate.library = library
                    #endif
                    #if DEBUG && os(macOS)
                    if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
                        if let folderIndex = CommandLine.arguments.firstIndex(of: "--audio-folder"), CommandLine.arguments.count > folderIndex + 1 {
                            files.openFolder(URL(fileURLWithPath: CommandLine.arguments[folderIndex + 1]))
                        }
                        do {
                            try await AppPreview.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), files: files)
                            files.shutdown(); exit(0)
                        } catch { fputs("\(error.localizedDescription)\n", stderr); files.shutdown(); exit(1) }
                    }
                    #endif
                    if CommandLine.arguments.contains("--smoke-test") {
                        let savedOutput = UserDefaults.standard.string(forKey: "outputUID")
                        defer { if let savedOutput { UserDefaults.standard.set(savedOutput, forKey: "outputUID") } }
                        if CommandLine.arguments.contains("--smoke-direct"), let direct = model.outputs.first(where: \.isAM4) { model.outputUID = direct.uid }
                        print("Smoke: requesting loop audio")
                        await model.startAutomatically()
                        print("Smoke: loop audio returned running=\(model.running) error=\(model.error ?? "none")")
                        guard model.running else { print("FAIL: " + (model.error ?? "Audio did not start")); model.shutdown(); exit(1) }
                        let player = FilePlayback(), token = UUID()
                        var fileExpected = false
                        var restartContinued = true
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
                        try? await Task.sleep(for: .seconds(3))
                        let file = await player.snapshot(session: token)
                        let success = restartContinued && library.selectedSongID == nil && model.running && model.error == nil && model.audioCallbackCount > 100 && model.audioCallbackFrames == 32
                            && (!fileExpected || (file?.playing == true && (file?.position ?? 0) > 0.1))
                        print(success ? "PASS: AM4 input → AM4 Proxy output at \(Int(model.sampleRate)) Hz; \(model.audioCallbackFrames) samples; \(model.audioCallbackCount) callbacks; concurrent silent file playback: \(fileExpected); restart kept playback: \(restartContinued); no chart selected; no live monitoring." : "FAIL: \(model.error ?? "Audio stopped or callbacks did not advance")")
                        await player.unload()
                        model.stopAudio()
                        exit(success ? 0 : 1)
                    }
                    // Hosted unit tests exercise DSP without opening physical I/O.
                    if NSClassFromString("XCTestCase") == nil { await model.startAutomatically() }

                }
        }
        #if os(macOS)
        .defaultSize(width: 1320, height: 860)
        .windowResizability(.contentMinSize)
        #endif
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Backing Track") {
                Button("Restart Track") { files.restart() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!files.playing || files.loading)
            }
            CommandMenu("Loop") {
                Button("Arm") { Task { await model.arm() } }.keyboardShortcut("r", modifiers: []).disabled(!model.canEditTiming)
                Button("Play / Stop") { model.playStop() }.keyboardShortcut(.space, modifiers: []).disabled(!model.hasLoop && !model.busy)
                Button("Clear") { model.clear() }.keyboardShortcut(.delete, modifiers: []).disabled(model.state == 0)
            }
        }
    }
}
