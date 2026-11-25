import SwiftUI
import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import LooperCore
import JamCore

@MainActor @Observable final class LoopTelemetry {
    var progress = 0.0
    var recorded = 0
    var meterDB = -90.0
    var outputDB = -90.0
    var waveform = [Float](repeating: 0, count: 256)
    var cycles: UInt64 = 0
}

@MainActor final class LooperModel: ObservableObject {
    let midi = JamMIDIInput()
    @Published var devices: [AudioDevice] = []
    @Published var inputUID = UserDefaults.standard.string(forKey: "inputUID") ?? ""
    @Published var outputUID = UserDefaults.standard.string(forKey: "outputUID") ?? ""
    @Published var inputChannel = 0
    @Published var bpm = 120.0 { didSet { host.drums.tempo = bpm } }
    @Published var bars = 4
    @Published var thresholdDB = -30.0 { didSet { if let core { tl_set_threshold(core, thresholdLinear) } } }
    private var thresholdLinear: Float { Float(pow(10, thresholdDB / 20)) }
    @Published var volume = 1.0 { didSet { if let core { tl_set_volume(core, Float(volume)) } } }
    @Published private(set) var audioPaused = false
    private var lifecyclePolicy = AudioLifecyclePolicy()
    @Published var running = false
    @Published var starting = false
    @Published var error: String?
    @Published var requestingLoopFile = false
    @Published var loopFileFailure: String?
    @Published var saveRequest: LoopSaveRequest?
    @Published var pendingRecall: LoopRecall?
    @Published private(set) var fileBusy = false
    @Published private(set) var loopName: String?
    @Published private(set) var savedLoopURL: URL?
    @Published private(set) var loopLibraryFolder: URL?
    @Published private(set) var savedLoops: [SavedLoopFile] = []
    @Published private(set) var readingSavedLoops = false
    @Published private(set) var savedLoopsError: String?
    private let loopFiles: LoopFiles
    private var loopFolderRevision = UUID()
    private var recalled = false
    private var loopIsSaved = false
    private var takeID = UUID()
    @Published private(set) var restoringLoop = false
    var controlsAvailable: Bool { !restoringLoop && pendingRecall == nil }
    @Published var state = Int32(TL_EMPTY)
    let telemetry = LoopTelemetry()
    var progress: Double {
        get { telemetry.progress }
        set { telemetry.progress = newValue }
    }
    var recorded: Int {
        get { telemetry.recorded }
        set { telemetry.recorded = newValue }
    }
    @Published var length = 0
    var meterDB: Double {
        get { telemetry.meterDB }
        set { telemetry.meterDB = newValue }
    }
    var outputDB: Double {
        get { telemetry.outputDB }
        set { telemetry.outputDB = newValue }
    }
    var waveform: [Float] {
        get { telemetry.waveform }
        set { telemetry.waveform = newValue }
    }
    @Published var sampleRate = 48000.0
    var cycles: UInt64 {
        get { telemetry.cycles }
        set { telemetry.cycles = newValue }
    }
    private let host: AudioEngineHost
    private var core: OpaquePointer? { host.core }
    private var stopTask: Task<Void, Never>?
    private var timer: Timer?
    private var ticks = 0
    private var lastCallbacks: UInt64 = 0
    private var stalledTicks = 0
    private var generation = 0
    private var automaticAudio = false
    private var lastAutomaticRoute: String?
    private var routeTask: Task<Void, Never>?
    private var scanningDevices = false
    private var rescanDevices = false
    #if os(macOS)
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private func observeDevices() {
        guard deviceListener == nil else { return }
        var address = AudioDevices.address(kAudioHardwarePropertyDevices)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshDevicesWhileRunning() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            deviceListener = listener
        }
    }
    private func stopObservingDevices() {
        guard let deviceListener else { return }
        var address = AudioDevices.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
        self.deviceListener = nil
    }
    #endif

    init(loopFiles: LoopFiles = LoopFiles(), host: AudioEngineHost? = nil) {
        self.host = host ?? AudioEngineHost.shared
        self.loopFiles = loopFiles
        refreshDevices()
        #if os(macOS)
        if LaunchOptions.has("--smoke-direct"), let direct = outputs.first(where: \.isAM4) { outputUID = direct.uid }
        #endif
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    var audioCallbackCount: UInt64 { host.callbacks }
    var audioCallbackFrames: UInt32 { host.callbackFrames }
    var inputs: [AudioDevice] { devices.filter { $0.inputs > 0 } }
    var outputs: [AudioDevice] { devices.filter { $0.outputs > 0 } }
    var input: AudioDevice? { inputs.first { $0.uid == inputUID } }
    var output: AudioDevice? { outputs.first { $0.uid == outputUID } }
    var hasLoop: Bool { state == TL_PLAYING || state == TL_STOPPED || state == TL_WAITING }
    var canEditTiming: Bool { state == TL_EMPTY && !starting && controlsAvailable }
    var canRecord: Bool { controlsAvailable && !starting && !audioPaused && (state == TL_EMPTY || state == TL_ARMED || state == TL_RECORDING) }
    var canSave: Bool { !fileBusy && hasLoop && !starting && !audioPaused && controlsAvailable }
    var canRecall: Bool { !fileBusy && !busy && !starting && !audioPaused && controlsAvailable }
    var acceptsMIDI: Bool { lifecyclePolicy.mayConnect && !audioPaused && controlsAvailable }
    var busy: Bool { state == TL_ARMED || state == TL_RECORDING }
    var plannedFrames: UInt32 { tl_loop_frames(sampleRate, bpm, UInt32(bars), 4) }
    var seconds: Double { hasLoop ? Double(length) / sampleRate : 60 / bpm * 4 * Double(bars) }
    var status: String {
        if starting { return "Connecting…" }
        if !running { return "Ready when you are" }
        switch state {
        case Int32(TL_ARMED): return "Waiting for your strum"
        case Int32(TL_RECORDING): return "Recording"
        case Int32(TL_PLAYING): return "Looping"
        case Int32(TL_WAITING): return "Waiting for drummer"
        case Int32(TL_STOPPED): return "Stopped"
        default: return "Ready to arm"
        }
    }
    var detail: String {
        if fileBusy { return "Transferring loop…" }
        switch state {
        case Int32(TL_WAITING): return "Waiting for drummer’s next beat 1 · Stop cancels"
        case Int32(TL_ARMED): return "Cross \(Int(thresholdDB)) dB to begin · \(bars) bars at \(Int(bpm)) BPM"
        case Int32(TL_RECORDING):
            let remaining = max(0, Double(length - recorded) / sampleRate)
            return String(format: "%.1f seconds remaining", remaining)
        case Int32(TL_PLAYING):
            if length < Int(plannedFrames) { return String(format: "%.2f s loop · %llu passes", Double(length) / sampleRate, cycles) }
            return "Bar \(min(bars, Int(progress * Double(bars)) + 1)) of \(bars) · \(cycles) passes"
        case Int32(TL_STOPPED): return [loopName, recalled ? "Play starts on the drummer’s next beat 1 when running" : "Play restarts your loop from the beginning"].compactMap { $0 }.joined(separator: " · ")
        default: return "Arm, then play. Your first strum starts the loop."
        }
    }
    func refreshDevices() {
        do { applyDevices(try AudioDevices.list()) }
        catch { self.error = error.localizedDescription }
    }
    private func applyDevices(_ next: [AudioDevice]) {
        if devices != next { devices = next }
        #if os(macOS)
        if inputUID.isEmpty { inputUID = inputs.first(where: \.isAM4)?.uid ?? "" }
        if outputUID.isEmpty { outputUID = outputs.first(where: { $0.name == "AM4 Proxy" })?.uid ?? "" }
        #else
        if inputUID.isEmpty || inputUID.hasPrefix("AppleUSBAudio") { inputUID = "ios-default-input" }
        if outputUID != "ios-system-output" { outputUID = "ios-system-output" }
        #endif
    }
    private func refreshDevicesWhileRunning() {
        #if os(macOS)
        guard !scanningDevices else { rescanDevices = true; return }
        scanningDevices = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try AudioDevices.list() } }.value
            guard let self else { return }
            self.scanningDevices = false
            switch result {
            case .success(let next): self.applyDevices(next)
            case .failure(let error): self.error = error.localizedDescription
            }
            self.reconnectIfAvailable()
            if self.rescanDevices {
                self.rescanDevices = false
                self.refreshDevicesWhileRunning()
            }
        }
        #else
        refreshDevices(); reconnectIfAvailable()
        #endif
    }
    // Startup connects the route, but never arms a loop or starts backing playback.
    func startAutomatically() async {
        #if os(macOS)
        observeDevices()
        #endif
        guard !automaticAudio else { return }
        automaticAudio = true
        lastAutomaticRoute = automaticRouteKey
        if !fileBusy && !hasLoop { await startAudio() }
    }
    private var automaticRouteKey: String? {
        guard let input, let output else { return nil }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if input.uid == "ios-default-input" {
            let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio })
                ?? session.currentRoute.outputs.first(where: { $0.portType == .usbAudio })
            guard let usb else { return nil }
            return "\(usb.uid)|\(inputChannel)"
        }
        #endif
        return "\(input.uid)|\(input.id)|\(output.uid)|\(output.id)|\(inputChannel)"
    }
    func routeDidChange() {
        guard automaticAudio, lifecyclePolicy.mayConnect, !audioPaused else { return }
        routeTask?.cancel()
        stopAudio()
        routeTask = Task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            lastAutomaticRoute = automaticRouteKey
            await startAudio()
        }
    }
    private func reconnectIfAvailable() {
        guard automaticAudio, lifecyclePolicy.mayConnect, !audioPaused, !running, !starting else { return }
        guard let route = automaticRouteKey else { lastAutomaticRoute = nil; return }
        guard route != lastAutomaticRoute else { return }
        lastAutomaticRoute = route
        Task { await startAudio() }
    }
    private static var microphoneHelp: String {
        #if os(macOS)
        "Allow Mac Jams in System Settings → Privacy & Security → Microphone."
        #else
        "Allow Mac Jams in Settings → Privacy & Security → Microphone."
        #endif
    }
    func startAudio() async {
        guard lifecyclePolicy.mayConnect, (!running || (!host.captureEnabled && state == TL_EMPTY)), !starting else { return }
        starting = true; error = nil
        generation += 1
        let token = generation
        defer { if token == generation { starting = false } }
        do {
            if host.suspended, try await host.resumeSuspendedAudio(),
               host.captureEnabled || host.core.map({ tl_snapshot($0).state != TL_EMPTY }) == true {
                guard token == generation else { return }
                running = true; audioPaused = false; lastCallbacks = 0; stalledTicks = 0
                return
            }
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            if permission == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw AudioFailure(message: Self.microphoneHelp)
                }
            } else if permission != .authorized {
                throw AudioFailure(message: Self.microphoneHelp)
            }
            guard token == generation else { return }
            refreshDevices()
            guard let input, let output else { throw AudioFailure(message: "Connect your interface and choose an available input and output in Audio Settings.") }
            if let stopTask { await stopTask.value; self.stopTask = nil }
            try await host.startLoop(input: input, output: output, channel: inputChannel)
            guard token == generation else { await host.stopLoop(); return }
            sampleRate = host.sampleRate
            guard let core else { throw AudioFailure(message: "The guitar processor did not initialize.") }
            tl_set_threshold(core, thresholdLinear); tl_set_volume(core, Float(volume))
            if !LaunchOptions.has("--smoke-test") {
                UserDefaults.standard.set(inputUID, forKey: "inputUID"); UserDefaults.standard.set(outputUID, forKey: "outputUID")
            }
            running = true; audioPaused = false; lastCallbacks = 0; stalledTicks = 0
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            if !host.suspended { stopAudio() }
            self.error = error.localizedDescription
        }
    }
    func handleAudioLifecycle(_ event: AudioLifecyclePolicy.Event) {
        switch lifecyclePolicy.handle(event) {
        case .none: break
        case .suspend:
            generation += 1; routeTask?.cancel(); stopTask?.cancel()
            host.suspendAudio(); running = false; starting = false; audioPaused = true
            if let core {
                let snapshot = tl_snapshot(core)
                state = snapshot.state; length = Int(snapshot.length); recorded = Int(snapshot.recorded)
            }
            if state == TL_EMPTY { waveform = [Float](repeating: 0, count: 256) }
            meterDB = -90; outputDB = -90
            error = "Audio paused. Playback stays stopped when you return."
        case .reconnect: Task { await startAudio() }
        case .reset:
            generation += 1; routeTask?.cancel(); stopTask?.cancel()
            host.resetAudioService(); running = false; starting = false; audioPaused = false
            state = Int32(TL_EMPTY); length = 0; recorded = 0; progress = 0; cycles = 0
            waveform = [Float](repeating: 0, count: 256)
            error = "iPad audio services restarted. The guitar loop was cleared. Use Retry Connection; playback stays stopped."
        }
    }
    func retryAudio() async {
        guard lifecyclePolicy.handle(.retry) == .reconnect else { return }
        await startAudio()
    }
    func stopAudio() {
        generation += 1
        stopTask?.cancel()
        stopTask = Task { await host.stopLoop() }
        running = false; starting = false; audioPaused = false; state = Int32(TL_EMPTY)
        progress = 0; recorded = 0; length = 0; meterDB = -90; outputDB = -90; cycles = 0
        waveform = [Float](repeating: 0, count: 256)
        newTake()
    }
    func arm() async {
        guard controlsAvailable else { return }
        if !running || !host.captureEnabled { await startAudio() }
        guard controlsAvailable, running, let core, state == TL_EMPTY else { return }
        if !tl_command(core, Int32(TL_CMD_ARM), plannedFrames) { error = "Audio controls are busy. Try again." }
        else { newTake(); state = Int32(TL_ARMED); length = Int(plannedFrames) }
    }
    func record() async {
        guard controlsAvailable else { return }
        if !running || !host.captureEnabled { await startAudio() }
        guard controlsAvailable, running, let core else { return }
        // The audio thread decides start/finish, avoiding races with the 30 Hz display.
        if !tl_command(core, Int32(TL_CMD_RECORD), plannedFrames) { error = "Audio controls are busy. Try again." }
        else if state == TL_EMPTY || state == TL_ARMED { if state == TL_EMPTY { newTake() }; state = Int32(TL_RECORDING); length = Int(plannedFrames) }
    }
    func clear() {
        guard controlsAvailable else { return }
        if audioPaused {
            host.shutdown(); audioPaused = false; state = Int32(TL_EMPTY); length = 0; recorded = 0; progress = 0; cycles = 0
            newTake()
            waveform = [Float](repeating: 0, count: 256)
            Task { await retryAudio() }
            return
        }
        guard let core else { return }
        if !tl_command(core, Int32(TL_CMD_CLEAR), 0) { error = "Audio controls are busy. Try again." }
        else { newTake() }
    }
    func playStop() {
        guard controlsAvailable else { return }
        if audioPaused {
            Task { await retryAudio(); if running { playStop() } }
            return
        }
        guard let core else { return }
        if !tl_command(core, Int32(recalled ? TL_CMD_PLAY_SYNC : TL_CMD_PLAY_STOP), 0) { error = "Audio controls are busy. Try again." }
    }
    private func newTake() {
        takeID = UUID(); loopIsSaved = false; recalled = false; loopName = nil; savedLoopURL = nil
    }
    func configureLoopLibrary(_ folder: URL) {
        guard folder != loopLibraryFolder else { return }
        loopFolderRevision = UUID(); loopLibraryFolder = folder
        savedLoops = []; savedLoopsError = nil; readingSavedLoops = false
    }
    func refreshSavedLoops() async {
        guard let folder = loopLibraryFolder else { savedLoopsError = LoopStorageError.chooseLibrary.localizedDescription; return }
        let revision = loopFolderRevision
        readingSavedLoops = true; savedLoopsError = nil
        defer { if revision == loopFolderRevision { readingSavedLoops = false } }
        do {
            let entries = try await loopFiles.list(in: folder)
            guard revision == loopFolderRevision else { return }
            savedLoops = entries
        } catch { if revision == loopFolderRevision { savedLoopsError = error.localizedDescription } }
    }
    func saveLoop() async {
        guard canSave else { return }
        fileBusy = true
        defer { fileBusy = false }
        let id = takeID, tempo = bpm, count = bars
        do {
            guard let folder = loopLibraryFolder else { throw LoopStorageError.chooseLibrary }
            let loop = try await host.snapshotLoop(bpm: tempo, bars: count)
            guard id == takeID else { return }
            saveRequest = LoopSaveRequest(id: id, loop: loop, name: loopName ?? "Loop \(Int(tempo)) BPM", libraryFolder: folder)
        } catch { loopFileFailure = error.localizedDescription }
    }
    func storeLoop(_ request: LoopSaveRequest, name: String) async {
        guard !fileBusy else { return }
        guard loopLibraryFolder == request.libraryFolder else { loopFileFailure = "The library folder changed. Save the loop again to use its Loops folder."; return }
        fileBusy = true
        defer { fileBusy = false }
        do {
            let file = try await loopFiles.save(request.loop, name: name, in: request.libraryFolder)
            if request.id == takeID { loopIsSaved = true; loopName = file.name; savedLoopURL = file.url }
            await refreshSavedLoops()
        } catch { loopFileFailure = error.localizedDescription }
    }
    func openLoop(_ url: URL) async {
        // Finder/Files may deliver an open event while startup is still
        // connecting capture. Keep that intent instead of silently dropping it.
        if starting {
            let (updates, continuation) = AsyncStream<Void>.makeStream()
            let subscription = $starting.filter { !$0 }.sink { _ in continuation.finish() }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in updates {} }
                group.addTask { try? await Task.sleep(for: .seconds(30)) }
                await group.next()
                group.cancelAll()
            }
            subscription.cancel()
            guard !Task.isCancelled else { return }
        }
        guard canRecall else {
            if busy { loopFileFailure = "Finish recording before opening a saved loop." }
            else if starting { loopFileFailure = "Audio is still connecting. Try opening the loop again in a moment." }
            return
        }
        fileBusy = true
        let initialTake = takeID, initialGeneration = generation, revision = loopFolderRevision
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() }; fileBusy = false }
        do {
            let loop = try await loopFiles.read(url)
            guard initialTake == takeID, initialGeneration == generation, revision == loopFolderRevision, !busy, !starting, lifecyclePolicy.mayConnect else { return }
            let recall = LoopRecall(loop: loop, name: url.deletingPathExtension().lastPathComponent, url: url)
            if hasLoop && !loopIsSaved { pendingRecall = recall }
            else { try await applyRecall(recall) }
        } catch { loopFileFailure = error.localizedDescription }
    }
    func confirmRecall() async {
        guard let recall = pendingRecall else { return }
        pendingRecall = nil; fileBusy = true
        defer { fileBusy = false }
        do { try await applyRecall(recall) } catch { loopFileFailure = error.localizedDescription }
    }
    private func applyRecall(_ recall: LoopRecall) async throws {
        guard lifecyclePolicy.mayConnect, let output else { throw AudioFailure(message: "Choose an output in Audio Settings before opening a loop.") }
        restoringLoop = true
        defer { restoringLoop = false }
        if let stopTask { await stopTask.value; self.stopTask = nil }
        try await host.prepareLoopRecall(output: output)
        try await host.restoreLoop(recall.loop)
        takeID = UUID(); loopName = recall.name; recalled = true; loopIsSaved = true
        savedLoopURL = recall.url
        bpm = recall.loop.bpm; bars = recall.loop.bars; sampleRate = host.sampleRate
        running = true; audioPaused = false; lastCallbacks = host.callbacks; stalledTicks = 0
        error = nil
        state = Int32(TL_STOPPED)
        if let core {
            tl_set_volume(core, Float(volume)); tl_set_threshold(core, thresholdLinear)
            let snapshot = tl_snapshot(core); length = Int(snapshot.length); recorded = Int(snapshot.recorded)
            waveform = (0..<256).map { tl_waveform(core, UInt32($0)) }
        }
        progress = 0; cycles = 0
    }
    func shutdown() {
        #if os(macOS)
        stopObservingDevices()
        #endif
        generation += 1
        midi.stop()
        automaticAudio = false; routeTask?.cancel(); stopTask?.cancel(); timer?.invalidate(); host.shutdown(); running = false
    }
    private static func decibels(_ peak: Float) -> Double { max(-90, 20 * log10(max(Double(peak), 0.00003))) }
    private func poll() {
        guard lifecyclePolicy.mayConnect, !audioPaused else { return }
        ticks += 1
        if ticks % 60 == 0 {
            #if os(macOS)
            if deviceListener == nil { refreshDevicesWhileRunning() }
            #endif
            if running, (!host.isRunning || (output.map { !AudioDevices.alive($0.id) } ?? true)) {
                stopAudio(); error = "The audio device disconnected or its sample rate changed. Reconnect the interface or use Retry Connection in Settings."
            }
            reconnectIfAvailable()
        }
        guard running, !restoringLoop, let core else { return }
        let callbacks = host.callbacks
        stalledTicks = callbacks == lastCallbacks ? stalledTicks + 1 : 0
        lastCallbacks = callbacks
        if host.renderError != 0 || stalledTicks > 90 {
            let code = host.renderError
            let frames = audioCallbackFrames
            stopAudio()
            error = code == TL_BUFFER_SIZE_ERROR
                ? "The audio driver delivered \(frames) samples instead of 32. Audio was stopped."
                : "Audio stopped responding (Core Audio \(code)). Check your devices and use Retry Connection in Settings."
            return
        }
        let s = tl_snapshot(core)
        let stateChanged = state != s.state
        if stateChanged { state = s.state }
        if recorded != Int(s.recorded) { recorded = Int(s.recorded) }
        if length != Int(s.length) { length = Int(s.length) }
        if cycles != s.cycles { cycles = s.cycles }
        let nextProgress = s.length == 0 ? 0 : Double(s.state == TL_RECORDING ? s.recorded : s.position) / Double(s.length)
        if progress != nextProgress { progress = nextProgress }
        let peaks = tl_take_meter_peaks(core)
        let newDB = Self.decibels(peaks.input)
        let nextMeter = max(newDB, meterDB - 2.0)
        if meterDB != nextMeter { meterDB = nextMeter }
        let nextOutput = Self.decibels(peaks.output)
        if outputDB != nextOutput { outputDB = nextOutput }
        if stateChanged || (state == TL_RECORDING && ticks % 3 == 0) {
            waveform = state == TL_EMPTY ? [Float](repeating: 0, count: 256) : (0..<256).map { tl_waveform(core, UInt32($0)) }
        }
    }
}
