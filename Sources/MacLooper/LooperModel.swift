import SwiftUI
import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import LooperCore

@MainActor final class LooperModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var inputUID = UserDefaults.standard.string(forKey: "inputUID") ?? ""
    @Published var outputUID = UserDefaults.standard.string(forKey: "outputUID") ?? ""
    @Published var inputChannel = 0
    @Published var bpm = 120.0
    @Published var bars = 4
    @Published var thresholdDB = -30.0 { didSet { if let core { tl_set_threshold(core, Float(pow(10, thresholdDB / 20))) } } }
    @Published var volume = 0.7 { didSet { if let core { tl_set_volume(core, Float(volume)) } } }
    @Published var running = false
    @Published var starting = false
    @Published var error: String?
    @Published var state = Int32(TL_EMPTY)
    @Published var progress = 0.0
    @Published var recorded = 0
    @Published var length = 0
    @Published var meterDB = -90.0
    @Published var outputDB = -90.0
    @Published var waveform = [Float](repeating: 0, count: 256)
    @Published var sampleRate = 48000.0
    @Published var cycles: UInt64 = 0
    private let host = AudioEngineHost.shared
    private var core: OpaquePointer? { host.core }
    private var stopTask: Task<Void, Never>?
    private var timer: Timer?
    private var ticks = 0
    private var lastCallbacks: UInt64 = 0
    private var stalledTicks = 0
    private var generation = 0

    init() {
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }
    var audioCallbackCount: UInt64 { host.callbacks }
    var audioCallbackFrames: UInt32 { host.callbackFrames }
    var inputs: [AudioDevice] { devices.filter { $0.inputs > 0 } }
    var outputs: [AudioDevice] { devices.filter { $0.outputs > 0 } }
    var input: AudioDevice? { inputs.first { $0.uid == inputUID } }
    var output: AudioDevice? { outputs.first { $0.uid == outputUID } }
    var hasLoop: Bool { state == TL_PLAYING || state == TL_STOPPED }
    var canEditTiming: Bool { state == TL_EMPTY && !starting }
    var busy: Bool { state == TL_ARMED || state == TL_RECORDING }
    var plannedFrames: UInt32 { tl_loop_frames(sampleRate, bpm, UInt32(bars), 4) }
    var seconds: Double { 60 / bpm * 4 * Double(bars) }
    var status: String {
        if starting { return "Connecting…" }
        if !running { return "Ready when you are" }
        switch state {
        case Int32(TL_ARMED): return "Waiting for your strum"
        case Int32(TL_RECORDING): return "Recording"
        case Int32(TL_PLAYING): return "Looping"
        case Int32(TL_STOPPED): return "Stopped"
        default: return "Ready to arm"
        }
    }
    var detail: String {
        switch state {
        case Int32(TL_ARMED): return "Cross \(Int(thresholdDB)) dB to begin · \(bars) bars at \(Int(bpm)) BPM"
        case Int32(TL_RECORDING):
            let remaining = max(0, Double(length - recorded) / sampleRate)
            return String(format: "%.1f seconds remaining", remaining)
        case Int32(TL_PLAYING): return "Bar \(min(bars, Int(progress * Double(bars)) + 1)) of \(bars) · \(cycles) passes"
        case Int32(TL_STOPPED): return "Play restarts your loop from the beginning"
        default: return "Arm, then play. Your first strum starts the loop."
        }
    }
    func refreshDevices() {
        do {
            devices = try AudioDevices.list()
            #if os(macOS)
            if inputUID.isEmpty { inputUID = inputs.first(where: \.isAM4)?.uid ?? "" }
            if outputUID.isEmpty { outputUID = outputs.first(where: { $0.name == "AM4 Proxy" })?.uid ?? "" }
            #else
            if inputUID.isEmpty || inputUID.hasPrefix("AppleUSBAudio") { inputUID = "ios-default-input" }
            outputUID = "ios-system-output"
            #endif
        } catch { self.error = error.localizedDescription }
    }
    private static var microphoneHelp: String {
        #if os(macOS)
        "Allow Mac Looper in System Settings → Privacy & Security → Microphone."
        #else
        "Allow Mac Looper in Settings → Privacy & Security → Microphone."
        #endif
    }
    func startAudio() async {
        guard !running, !starting else { return }
        starting = true; error = nil
        generation += 1
        let token = generation
        defer { if token == generation { starting = false } }
        do {
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
            tl_set_threshold(core, Float(pow(10, thresholdDB / 20))); tl_set_volume(core, Float(volume))
            UserDefaults.standard.set(inputUID, forKey: "inputUID"); UserDefaults.standard.set(outputUID, forKey: "outputUID")
            running = true; lastCallbacks = 0; stalledTicks = 0
        } catch {
            stopAudio()
            self.error = error.localizedDescription
        }
    }
    func stopAudio() {
        generation += 1
        stopTask?.cancel()
        stopTask = Task { await host.stopLoop() }
        running = false; starting = false; state = Int32(TL_EMPTY)
        progress = 0; recorded = 0; length = 0; meterDB = -90; outputDB = -90; cycles = 0
        waveform = [Float](repeating: 0, count: 256)
    }
    func arm() async {
        if !running { await startAudio() }
        guard running, let core, state == TL_EMPTY else { return }
        if !tl_command(core, Int32(TL_CMD_ARM), plannedFrames) { error = "Audio controls are busy. Try again." }
        else { state = Int32(TL_ARMED); length = Int(plannedFrames) }
    }
    func clear() {
        guard let core else { return }
        if !tl_command(core, Int32(TL_CMD_CLEAR), 0) { error = "Audio controls are busy. Try again." }
    }
    func playStop() {
        guard let core else { return }
        if !tl_command(core, Int32(TL_CMD_PLAY_STOP), 0) { error = "Audio controls are busy. Try again." }
    }
    func shutdown() {
        stopTask?.cancel(); timer?.invalidate(); host.shutdown(); running = false
    }
    private func poll() {
        ticks += 1
        if ticks % 60 == 0 {
            refreshDevices()
            if running, (!host.isRunning || (output.map { !AudioDevices.alive($0.id) } ?? true)) {
                stopAudio(); error = "The audio device disconnected or its sample rate changed. Reconnect and start audio again."
            }
        }
        guard running, let core else { return }
        let callbacks = host.callbacks
        stalledTicks = callbacks == lastCallbacks ? stalledTicks + 1 : 0
        lastCallbacks = callbacks
        if host.renderError != 0 || stalledTicks > 90 {
            let code = host.renderError
            let frames = audioCallbackFrames
            stopAudio()
            error = code == TL_BUFFER_SIZE_ERROR
                ? "The audio driver delivered \(frames) samples instead of 32. Audio was stopped."
                : "Audio stopped responding (Core Audio \(code)). Check your devices and start audio again."
            return
        }
        let s = tl_snapshot(core)
        state = s.state; recorded = Int(s.recorded); length = Int(s.length); cycles = s.cycles
        progress = s.length == 0 ? 0 : Double(s.state == TL_RECORDING ? s.recorded : s.position) / Double(s.length)
        let newDB = max(-90, 20 * log10(max(Double(s.peak), 0.00003)))
        meterDB = max(newDB, meterDB - 2.0)
        outputDB = max(-90, 20 * log10(max(Double(s.outputPeak), 0.00003)))
        if ticks % 3 == 0 { waveform = (0..<256).map { tl_waveform(core, UInt32($0)) } }
    }
}
