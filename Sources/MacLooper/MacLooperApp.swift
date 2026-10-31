import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: LooperModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.stopAudio() }
}

@main @MainActor struct MacLooperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = LooperModel()
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
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .task {
                    delegate.model = model
                    if CommandLine.arguments.contains("--smoke-test") {
                        await model.startAudio()
                        try? await Task.sleep(for: .seconds(3))
                        let success = model.running
                        print(success ? "PASS: AM4 input → AM4 Proxy output callbacks running at \(Int(model.sampleRate)) Hz; no live monitoring." : "FAIL: \(model.error ?? "Audio stopped")")
                        model.stopAudio()
                        exit(success ? 0 : 1)
                    }
                }
        }
        .windowResizability(.contentSize)
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
