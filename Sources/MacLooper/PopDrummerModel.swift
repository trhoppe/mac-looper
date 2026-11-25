import SwiftUI
import AVFoundation
import AudioToolbox
import CoreAudioKit
import LooperAudioUnit
#if os(macOS)
import AppKit
typealias PluginEditorController = NSViewController
#else
import UIKit
typealias PluginEditorController = UIViewController
#endif

@MainActor private final class PluginLoadRequest {
    var continuation: CheckedContinuation<AVAudioUnit, Error>?
    init(_ continuation: CheckedContinuation<AVAudioUnit, Error>) { self.continuation = continuation }
    func finish(_ result: Result<AVAudioUnit, Error>) {
        guard let continuation else { return }
        self.continuation = nil; continuation.resume(with: result)
    }
}

@MainActor final class PopDrummerModel: ObservableObject {
    struct Rhythm: Identifiable, Equatable {
        let id: Int
        let name: String
        var displayName: String { PopDrummerModel.rhythmDisplayName(name) ?? name }
    }
    // Current full audio instrument. Never select the old or MIDI-only component.
    static let component = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
        componentSubType: 0x706f7064, componentManufacturer: 0x4c6d4274, componentFlags: 0, componentFlagsMask: 0)
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var playing = false
    @Published var error: String?
    @Published var showingEditor = false
    @Published private(set) var rhythms: [Rhythm] = []
    @Published private(set) var selectedRhythmID: Int?
    @Published private(set) var selectingRhythm = false
    @Published private(set) var selectedRhythmName: String?
    @Published private(set) var editor: PluginEditorController?
    @Published var tempo = 120.0 { didSet { transport.tempo = tempo } }
    @Published var volume = 1.0 {
        didSet {
            if !volume.isFinite { volume = oldValue; return }
            let clipped = min(1, max(0, volume))
            if clipped != volume { volume = clipped; return }
            AudioEngineHost.shared.updateDrummerVolume()
        }
    }
    private(set) var node: AVAudioUnit?
    let transport = MLPluginTransport()
    private var loadTask: Task<Void, Never>?
    private var failureCached = false
    private var loadGeneration = UUID()
    private var transportIntent = UUID()
    private var registrationObserver: NSObjectProtocol?
    private let instrumentLoader: (() async throws -> AVAudioUnit)?
    private var rhythmTree: AUParameterTree?
    private var rhythmObserver: AUParameterObserverToken?
    private var rhythmSaveTask: Task<Void, Never>?
    init(instrumentLoader: (() async throws -> AVAudioUnit)? = nil) {
        self.instrumentLoader = instrumentLoader
        registrationObserver = NotificationCenter.default.addObserver(
            forName: AVAudioUnitComponentManager.registrationsChangedNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.componentsChanged() }
            }
    }
    deinit {
        rhythmSaveTask?.cancel()
        if let rhythmObserver { rhythmTree?.removeParameterObserver(rhythmObserver) }
        // Detach while AVAudioUnit still owns its underlying unit. In particular,
        // an AUv2 bridge must not be left with callbacks during wrapper teardown.
        transport.detach()
        if let registrationObserver { NotificationCenter.default.removeObserver(registrationObserver) }
    }
    func componentsChanged() { failureCached = false }
    func retry() async { failureCached = false; await prepare() }
    private var pendingState: [String: Any]?
    #if os(macOS)
    private var editorWindow: NSWindow?
    private var windowDelegate: DrummerWindowDelegate?
    #endif
    private var stateURL: URL {
        if let path = LaunchOptions.value("--plugin-state") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacLooper/PopDrummer-state.plist")
    }
    func prepare() async {
        if ready { return }
        if let loadTask { await loadTask.value; return }
        guard !failureCached else { return }
        let generation = loadGeneration
        let task = Task { @MainActor in
            self.loading = true; self.error = nil
            defer { if generation == loadGeneration { self.loading = false } }
            do {
                let node: AVAudioUnit
                if let instrumentLoader { node = try await instrumentLoader() }
                else {
                let requested = Self.component
                let manager = AVAudioUnitComponentManager.shared()
                var matches = manager.components(matching: requested)
                for _ in 0..<30 where matches.isEmpty {
                    try await Task.sleep(for: .milliseconds(100))
                    matches = manager.components(matching: requested)
                }
                if LaunchOptions.has("--drummer-check") {
                    let any = AudioComponentDescription(componentType: 0, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
                    for c in manager.components(matching: any) where c.name.localizedCaseInsensitiveContains("drummer") || c.manufacturerName.localizedCaseInsensitiveContains("lumbeat") {
                        print("Available plugin: \(c.name), type=\(String(c.audioComponentDescription.componentType, radix: 16)), sub=\(String(c.audioComponentDescription.componentSubType, radix: 16)), maker=\(String(c.audioComponentDescription.componentManufacturer, radix: 16))")
                    }
                }
                guard let description = matches.first?.audioComponentDescription else {
                    throw AudioFailure(message: "Pop Drummer AUv3 isn’t available. Open Pop Drummer once, then press Retry here.")
                }
                node = try await Self.instantiate(description)
                }
                guard generation == loadGeneration, !Task.isCancelled else { return }
                guard node.auAudioUnit.outputBusses.count > 0 else { throw AudioFailure(message: "Pop Drummer has no audio output.") }
                if instrumentLoader == nil, !LaunchOptions.has("--fresh-plugin"), let data = try? Data(contentsOf: self.stateURL),
                   let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    self.pendingState = state
                }
                node.auAudioUnit.contextName = "Mac Jams · Drums"
                self.transport.tempo = self.tempo
                self.transport.attach(to: node.auAudioUnit)
                self.node = node; self.ready = true
                self.observeRhythms()
            } catch {
                if generation == loadGeneration { self.failureCached = true; self.error = error.localizedDescription }
            }
        }
        loadTask = task
        await task.value
        if generation == loadGeneration { loadTask = nil }
    }
    func resetAfterAudioServiceReset() {
        rhythmSaveTask?.cancel()
        if let rhythmObserver { rhythmTree?.removeParameterObserver(rhythmObserver) }
        rhythmObserver = nil; rhythmTree = nil; rhythms = []; selectedRhythmID = nil; selectedRhythmName = nil; selectingRhythm = false
        loadGeneration = UUID(); loadTask?.cancel(); loadTask = nil
        setPlaying(false); transport.detach(); node = nil; ready = false; loading = false
        failureCached = false; pendingState = nil; editor = nil; showingEditor = false
        #if os(macOS)
        editorWindow?.close(); editorWindow = nil
        #endif
    }
    private static func instantiate(_ description: AudioComponentDescription) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            let request = PluginLoadRequest(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                request.finish(.failure(AudioFailure(message: "Pop Drummer took too long to load. You can keep using the looper and backing player.")))
            }
            #if os(macOS)
            let options: AudioComponentInstantiationOptions = [.loadOutOfProcess]
            #else
            let options: AudioComponentInstantiationOptions = []
            #endif
            AVAudioUnit.instantiate(with: description, options: options) { node, error in
                Task { @MainActor in
                    if let node { request.finish(.success(node)) }
                    else { request.finish(.failure(error ?? AudioFailure(message: "Pop Drummer could not load."))) }
                }
            }
        }
    }
    // Lumbeat must have its host render resources before restoring a kit. Earlier
    // restoration starts its internal engine on the system device instead.
    func restoreStateWhenPrepared() {
        guard let node, node.engine != nil, node.auAudioUnit.renderResourcesAllocated, let state = pendingState else { return }
        node.auAudioUnit.fullState = state
        pendingState = nil
        refreshRhythms()
    }
    private func observeRhythms() {
        if let rhythmObserver { rhythmTree?.removeParameterObserver(rhythmObserver) }
        rhythmTree = node?.auAudioUnit.parameterTree
        let grooveAddress = rhythmTree?.allParameters.first { $0.identifier == "Param_Groove" }?.address
        rhythmObserver = rhythmTree?.token(byAddingParameterObserver: { [weak self] address, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if address == grooveAddress { self.refreshRhythms() }
                self.rhythmSaveTask?.cancel()
                self.rhythmSaveTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    self?.saveState()
                }
            }
        })
        refreshRhythms()
    }
    nonisolated static func rhythmDisplayName(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "User - "
        guard name.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let display = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? nil : display
    }
    static func rhythmChoices(_ parameter: AUParameter) -> [Rhythm] {
        (parameter.valueStrings ?? []).enumerated().compactMap { index, name -> Rhythm? in
            guard rhythmDisplayName(name) != nil,
                  Float(index) >= parameter.minValue, Float(index) <= parameter.maxValue else { return nil }
            return Rhythm(id: index, name: name)
        }.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    func refreshRhythms() {
        guard let parameter = node?.auAudioUnit.parameterTree?.allParameters.first(where: { $0.identifier == "Param_Groove" }) else {
            rhythms = []; selectedRhythmID = nil; selectedRhythmName = nil; return
        }
        let choices = Self.rhythmChoices(parameter)
        if rhythms != choices { rhythms = choices }
        let value = parameter.value
        let id = value.isFinite ? Int(value.rounded()) : -1
        selectedRhythmID = choices.contains { $0.id == id } ? id : nil
        selectedRhythmName = choices.first { $0.id == id }?.displayName
    }
    /// Load names and restore the saved setup without opening the editor or starting transport.
    func loadRhythms(output: AudioDevice?) async {
        await prepare()
        guard ready else { return }
        if let output {
            do { try await AudioEngineHost.shared.startDrummer(output: output); error = nil }
            catch { self.error = error.localizedDescription }
        }
        refreshRhythms()
    }
    func selectRhythm(_ rhythm: Rhythm, output: AudioDevice?) async {
        guard !selectingRhythm else { return }
        let generation = loadGeneration
        selectingRhythm = true
        defer { if generation == loadGeneration { selectingRhythm = false } }
        await loadRhythms(output: output)
        guard generation == loadGeneration else { return }
        guard let node, node.auAudioUnit.renderResourcesAllocated, pendingState == nil,
              let parameter = node.auAudioUnit.parameterTree?.allParameters.first(where: { $0.identifier == "Param_Groove" }) else { return }
        // Re-resolve the name after loading; user-library edits can change indices.
        let choices = Self.rhythmChoices(parameter)
        guard let current = choices.first(where: { $0 == rhythm }) ?? choices.first(where: { $0.name == rhythm.name }) else {
            error = "That rhythm is no longer available. Choose another rhythm."; refreshRhythms(); return
        }
        parameter.value = Float(current.id)
        refreshRhythms()
        // Allow the instrument to finish applying its groove before capturing state.
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        guard self.node === node else { return }
        refreshRhythms(); saveState()
    }
    func setPlaying(_ value: Bool) {
        if !value { transportIntent = UUID() }
        transport.isPlaying = value; playing = value
    }
    func toggle(output: AudioDevice?) async {
        if playing { setPlaying(false); AudioEngineHost.shared.updateDrummerVolume(); return }
        transportIntent = UUID(); let intent = transportIntent
        await prepare()
        guard ready, intent == transportIntent else { return }
        do {
            try await AudioEngineHost.shared.startDrummer(output: output)
            guard intent == transportIntent else { return }
            error = nil; setPlaying(true); AudioEngineHost.shared.updateDrummerVolume()
        } catch { if intent == transportIntent { self.error = error.localizedDescription } }
    }
    func openEditor() async {
        await prepare()
        guard let node else { return }
        do { try await AudioEngineHost.shared.prepareDrummerEditor() }
        catch { self.error = error.localizedDescription; return }
        if editor == nil {
            let controller: PluginEditorController? = await withCheckedContinuation { continuation in
                node.auAudioUnit.requestViewController { continuation.resume(returning: $0) }
            }
            guard let controller else { error = "Pop Drummer didn’t provide its editor. Its audio controls are still available."; return }
            editor = controller
        }
        #if os(macOS)
        if let editorWindow { editorWindow.makeKeyAndOrderFront(nil); return }
        guard let editor else { return }
        let window = NSWindow(contentViewController: editor)
        window.title = "Drummer"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        let preferred = editor.preferredContentSize
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 900)
        window.setContentSize(NSSize(width: min(available.width - 60, preferred.width > 300 ? preferred.width : 1000),
                                     height: min(available.height - 100, preferred.height > 300 ? preferred.height : 720)))
        window.minSize = NSSize(width: 640, height: 500)
        let delegate = DrummerWindowDelegate { [weak self] in self?.editorDidClose() }
        window.delegate = delegate; windowDelegate = delegate
        editorWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
        #else
        showingEditor = true
        #endif
    }
    func editorDidClose() {
        refreshRhythms()
        saveState()
    }
    func saveState() {
        guard instrumentLoader == nil, pendingState == nil, node?.auAudioUnit.renderResourcesAllocated == true,
              let state = node?.auAudioUnit.fullState,
              PropertyListSerialization.propertyList(state, isValidFor: .binary) else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0).write(to: stateURL, options: .atomic)
        } catch { self.error = "Couldn’t save Pop Drummer settings: \(error.localizedDescription)" }
    }
}
#if os(macOS)
@MainActor private final class DrummerWindowDelegate: NSObject, NSWindowDelegate {
    let closed: () -> Void
    init(closed: @escaping () -> Void) { self.closed = closed }
    func windowWillClose(_ notification: Notification) { closed() }
}
#endif
