import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: LooperModel?
    var files: AudioFilePlayerModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.stopAudio(); files?.shutdown() }
}

@main @MainActor struct MacLooperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = LooperModel()
    @StateObject private var files = AudioFilePlayerModel()
    init() {
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
            ContentView(model: model, files: files)
                .preferredColorScheme(.dark)
                .task {
                    delegate.model = model; delegate.files = files
                    #if DEBUG
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
                        await model.startAudio()
                        let player = FilePlayback(), token = UUID()
                        var fileExpected = false
                        if let index = CommandLine.arguments.firstIndex(of: "--smoke-file"), CommandLine.arguments.count > index + 1 {
                            fileExpected = true
                            do {
                                guard let output = model.output else { throw AudioFailure(message: "No output selected.") }
                                _ = try await player.load(URL(fileURLWithPath: CommandLine.arguments[index + 1]), session: token, volume: 0, repeating: true)
                                try await player.play(session: token, output: output)
                            } catch { model.error = error.localizedDescription }
                        }
                        try? await Task.sleep(for: .seconds(3))
                        let file = await player.snapshot(session: token)
                        let success = model.running && model.error == nil && model.audioCallbackCount > 100 && model.audioCallbackFrames == 32
                            && (!fileExpected || (file?.playing == true && (file?.position ?? 0) > 0.1))
                        print(success ? "PASS: AM4 input → AM4 Proxy output at \(Int(model.sampleRate)) Hz; \(model.audioCallbackFrames) samples; \(model.audioCallbackCount) callbacks; concurrent silent file playback: \(fileExpected); no live monitoring." : "FAIL: \(model.error ?? "Audio stopped or callbacks did not advance")")
                        await player.unload()
                        model.stopAudio()
                        exit(success ? 0 : 1)
                    }
                }
        }
        .defaultSize(width: 1061, height: 650)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Loop") {
                Button("Arm") { Task { await model.arm() } }.keyboardShortcut("r", modifiers: []).disabled(!model.canEditTiming)
                Button("Play / Stop") { model.playStop() }.keyboardShortcut(.space, modifiers: []).disabled(!model.hasLoop && !model.busy)
                Button("Clear") { model.clear() }.keyboardShortcut(.delete, modifiers: []).disabled(model.state == 0)
            }
        }
    }
}
