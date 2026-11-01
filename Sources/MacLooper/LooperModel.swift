import SwiftUI
import AVFoundation
import CoreAudio
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
    private var core: OpaquePointer?
    private var hardware: OpaquePointer?
    private var activeRoute: AudioDevices.Route?
    private var activeInput: AudioDevice?
    private var activeOutput: AudioDevice?
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
    var audioCallbackCount: UInt64 { tl_hardware_callbacks(hardware) }
    var audioCallbackFrames: UInt32 { tl_hardware_callback_frames(hardware) }
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
            if inputUID.isEmpty { inputUID = inputs.first(where: \.isAM4)?.uid ?? "" }
            if outputUID.isEmpty { outputUID = outputs.first(where: { $0.name == "AM4 Proxy" })?.uid ?? "" }
        } catch { self.error = error.localizedDescription }
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
                    throw AudioFailure(message: "Allow Mac Looper in System Settings → Privacy & Security → Microphone.")
                }
            } else if permission != .authorized {
                throw AudioFailure(message: "Allow Mac Looper in System Settings → Privacy & Security → Microphone.")
            }
            guard token == generation else { return }
            refreshDevices()
            guard let input, let output else { throw AudioFailure(message: "Connect AM4 and AM4 Proxy, or choose an available input and output.") }
            let route = try await AudioDevices.route(input: input, output: output)
            guard token == generation else { if let id = route.aggregate { AudioHardwareDestroyAggregateDevice(id) }; return }
            activeRoute = route; activeInput = input; activeOutput = output
            sampleRate = route.rate
            guard inputChannel >= 0, inputChannel < input.inputs else { throw AudioFailure(message: "Choose an available input channel.") }
            guard let newCore = tl_create(route.rate, UInt32(ceil(route.rate * 64)) + 4) else {
                throw AudioFailure(message: "Could not reserve loop memory.")
            }
            core = newCore
            tl_set_threshold(newCore, Float(pow(10, thresholdDB / 20))); tl_set_volume(newCore, Float(volume))
            var status: OSStatus = 0
            let il = route.inputOffset + inputChannel
            let ir = route.inputOffset + min(inputChannel + 1, input.inputs - 1)
            hardware = tl_hardware_create(newCore, route.device, route.rate, UInt32(route.inputs), UInt32(route.outputs),
                                          UInt32(il), UInt32(ir), UInt32(route.outputOffset),
                                          UInt32(route.outputOffset + min(1, output.outputs - 1)), &status)
            guard hardware != nil else { throw AudioFailure(message: "Could not open the selected audio route (Core Audio \(status)).") }
            try AudioDevices.check(tl_hardware_start(hardware), "Start audio")
            UserDefaults.standard.set(inputUID, forKey: "inputUID"); UserDefaults.standard.set(outputUID, forKey: "outputUID")
            running = true; lastCallbacks = 0; stalledTicks = 0
        } catch {
            stopAudio()
            self.error = error.localizedDescription
        }
    }
    func stopAudio() {
        generation += 1
        // Stop and dispose the AudioUnit before freeing callback-owned memory.
        tl_hardware_destroy(hardware); hardware = nil
        tl_destroy(core); core = nil
        if let aggregate = activeRoute?.aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
        activeRoute = nil; activeInput = nil; activeOutput = nil
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
    private func poll() {
        ticks += 1
        if ticks % 60 == 0 {
            refreshDevices()
            if running, let i = activeInput, let o = activeOutput,
               (!AudioDevices.alive(i.id) || !AudioDevices.alive(o.id) ||
                abs(AudioDevices.number(i.id, kAudioDevicePropertyNominalSampleRate, fallback: 0.0) - sampleRate) > 0.1 ||
                abs(AudioDevices.number(o.id, kAudioDevicePropertyNominalSampleRate, fallback: 0.0) - sampleRate) > 0.1) {
                stopAudio(); error = "The audio device disconnected or its sample rate changed. Reconnect and start audio again."
            }
        }
        guard running, let core, let hardware else { return }
        let callbacks = tl_hardware_callbacks(hardware)
        stalledTicks = callbacks == lastCallbacks ? stalledTicks + 1 : 0
        lastCallbacks = callbacks
        if tl_hardware_error(hardware) != 0 || stalledTicks > 90 {
            let code = tl_hardware_error(hardware)
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
