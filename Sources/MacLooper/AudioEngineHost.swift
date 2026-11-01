import Foundation
import AVFoundation
import AudioToolbox
import LooperCore
import LooperAudioUnit
#if os(macOS)
import CoreAudio
#endif

@MainActor final class AudioEngineHost {
    static let shared = AudioEngineHost()
    private static var registered = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var loopNode: AVAudioUnit?
    private(set) var loopUnit: MLGuitarLoopAudioUnit?
    private(set) var captureEnabled = false
    private(set) var sampleRate = 48000.0
    private(set) var actualBufferFrames = 0
    private var output: AudioDevice?
    private var input: AudioDevice?
    private var inputChannel = 0
    private var configuring = false
    #if os(macOS)
    private var aggregate: AudioDeviceID?
    private var macDriver: MLMacAudioDriver?
    #endif
    private var file: PlaybackAsset?
    private var fileSession: UUID?
    private var filePosition = 0.0
    private var filePlaying = false
    private var fileRepeat = false
    private var fileVolume: Float = 0.7
    private var segmentStart: AVAudioFramePosition = 0
    private var fileGeneration = UUID()
    private var fileScheduled = false

    var core: OpaquePointer? { loopUnit?.core }
    var callbacks: UInt64 { loopUnit?.callbackCount ?? 0 }
    var callbackFrames: UInt32 { loopUnit?.callbackFrames ?? 0 }
    var renderError: OSStatus {
        #if os(macOS)
        if let driver = macDriver, driver.renderError != 0 { return driver.renderError }
        #endif
        return loopUnit?.renderError ?? 0
    }
    var isRunning: Bool { engine?.isRunning == true }
    private func waitForConfiguration() async throws {
        for _ in 0..<500 {
            if !configuring { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AudioFailure(message: "The audio route is still connecting. Try again.")
    }
    func startLoop(input: AudioDevice, output: AudioDevice, channel: Int) async throws {
        try await waitForConfiguration()
        if captureEnabled, isRunning, self.input?.uid == input.uid, self.output?.uid == output.uid, inputChannel == channel { return }
        configuring = true; defer { configuring = false }
        self.input = input; self.output = output; inputChannel = channel
        let resumeBacking = filePlaying
        do { try await rebuild(capture: true) }
        catch {
            let captureError = error
            filePlaying = resumeBacking
            if file != nil { try? await rebuild(capture: false) }
            throw captureError
        }
    }
    func stopLoop() async {
        do {
            try await waitForConfiguration()
            configuring = true; defer { configuring = false }
            if captureEnabled {
                if file == nil { shutdownAudio() }
                else { try await rebuild(capture: false) }
            }
        } catch { shutdownAudio(); filePlaying = false }
    }
    func shutdown() { filePlaying = false; shutdownAudio() }
    private func shutdownAudio() {
        #if os(macOS)
        macDriver?.stop(); macDriver = nil
        #endif
        engine?.stop(); player?.stop()
        loopUnit = nil; loopNode = nil; player = nil; engine = nil; captureEnabled = false; fileScheduled = false
        #if os(macOS)
        if let aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = nil
        #endif
    }
    private func trace(_ value: String) { if CommandLine.arguments.contains("--smoke-test") { print("Audio: " + value) } }
    private func rebuild(capture: Bool) async throws {
        trace("rebuild capture=\(capture)")
        let resume = filePlaying
        filePosition = position()
        fileGeneration = UUID()
        shutdownAudio()
        guard let output else { throw AudioFailure(message: "Choose an output in Audio Settings.") }
        let e = AVAudioEngine(), p = AVAudioPlayerNode()
        self.engine = e; player = p
        var left = inputChannel, right = inputChannel + 1
        do {
            #if os(macOS)
            var captureRoute: AudioDevices.Route?
            if capture {
                guard let input else { throw AudioFailure(message: "Choose an input in Audio Settings.") }
                trace("routing hardware")
                let route = try await AudioDevices.route(input: input, output: output)
                trace("hardware route ready")
                captureRoute = route; aggregate = route.aggregate
                left += route.inputOffset; right = route.inputOffset + min(inputChannel + 1, input.inputs - 1)
                sampleRate = route.rate
                let inputFormat = try Self.captureFormat(rate: sampleRate, channels: UInt32(route.inputs))
                let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
                trace("create manual driver")
                macDriver = try MLMacAudioDriver(engine: e, inputFormat: inputFormat, outputFormat: outputFormat)
                actualBufferFrames = Int(AudioDevices.number(route.device, kAudioDevicePropertyBufferFrameSize, fallback: UInt32(0)))
            } else {
                guard AudioDevices.alive(output.id) else { throw AudioFailure(message: "The output device is disconnected.") }
                try AudioDevices.require32Frames(output.id, name: output.name)
                sampleRate = output.rate
                try e.outputNode.auAudioUnit.setDeviceID(output.id)
                actualBufferFrames = Int(AudioDevices.number(output.id, kAudioDevicePropertyBufferFrameSize, fallback: UInt32(0)))
            }
            #else
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(capture ? .playAndRecord : .playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(32.0 / 48000.0)
            try session.setActive(true)
            if capture {
                guard let port = (input?.uid == "ios-default-input"
                    ? session.availableInputs?.first(where: { $0.portType == .usbAudio })
                    : session.availableInputs?.first(where: { $0.uid == input?.uid })) else { throw AudioFailure(message: "Connect the AM4 or choose an available input in Audio Settings.") }
                try session.setPreferredInput(port)
                right = min(inputChannel + 1, Int(session.inputNumberOfChannels) - 1)
            }
            sampleRate = session.sampleRate
            actualBufferFrames = Int((session.ioBufferDuration * sampleRate).rounded())
            // iPadOS controls the hardware quantum. Request 32, accept the actual
            // route buffer, and report render callback sizes in the shared UI.
            #endif
            let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            trace("attach backing")
            e.attach(p)
            let backingFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            try MLAudioGraphTools.connect(e, source: p, sourceBus: 0, destination: e.mainMixerNode, destinationBus: 1, format: backingFormat)
            if capture {
                if !Self.registered {
                    AUAudioUnit.registerSubclass(MLGuitarLoopAudioUnit.self, as: Self.description, name: "Mac Looper: Guitar Loop", version: 1)
                    Self.registered = true
                }
                trace("instantiate loop")
                let node: AVAudioUnit = try await withCheckedThrowingContinuation { continuation in
                    AVAudioUnit.instantiate(with: Self.description, options: []) { unit, error in
                        if let unit { continuation.resume(returning: unit) }
                        else { continuation.resume(throwing: error ?? AudioFailure(message: "Could not create the guitar looper.")) }
                    }
                }
                trace("loop instantiated")
                guard let unit = node.auAudioUnit as? MLGuitarLoopAudioUnit else { throw AudioFailure(message: "Unexpected guitar processing unit.") }
                unit.inputLeft = UInt32(max(0, left)); unit.inputRight = UInt32(max(0, right)); #if os(macOS)
                unit.require32Frames = true
                #else
                unit.require32Frames = false
                #endif
                loopNode = node; loopUnit = unit
                e.attach(node)
                let native = e.inputNode.outputFormat(forBus: 0)
                guard native.channelCount > 0, left >= 0, right < native.channelCount else { throw AudioFailure(message: "The selected capture channels are unavailable (device supplied \(native.channelCount) channels).") }
                let format = try Self.captureFormat(rate: sampleRate, channels: native.channelCount)
                try MLAudioGraphTools.connect(e, source: e.inputNode, sourceBus: 0, destination: node, destinationBus: 0, format: format)
                try MLAudioGraphTools.connect(e, source: node, sourceBus: 0, destination: e.mainMixerNode, destinationBus: 0, format: stereo)
            }
            if !e.isInManualRenderingMode { try MLAudioGraphTools.connect(e, source: e.mainMixerNode, sourceBus: 0, destination: e.outputNode, destinationBus: 0, format: stereo) }
            trace("prepare graph")
            try MLAudioGraphTools.prepare(e)
            trace("start graph")
            if capture || resume { try MLAudioGraphTools.start(e) }
            trace("graph started")
            #if os(macOS)
            if let route = captureRoute, let driver = macDriver, let core = loopUnit?.core {
                trace("start hardware callbacks device=\(route.device) inputs=\(route.inputs) outputs=\(route.outputs) il=\(left) ir=\(right) ol=\(route.outputOffset) rate=\(route.rate)")
                try driver.start(with: core, device: route.device, rate: route.rate, inputs: UInt32(route.inputs), outputs: UInt32(route.outputs),
                                 inputLeft: UInt32(left), inputRight: UInt32(right), outputLeft: UInt32(route.outputOffset),
                                 outputRight: UInt32(route.outputOffset + min(1, output.outputs - 1)))
            }
            #endif
            trace("route running")
            captureEnabled = capture
            filePlaying = resume
            if file != nil { schedule(from: filePosition, play: resume) }
            p.volume = fileVolume
        } catch { shutdownAudio(); filePlaying = false; throw error }
    }
    static func captureFormat(rate: Double, channels: UInt32) throws -> AVAudioFormat {
        guard rate.isFinite, rate >= 8000, rate <= 192000, channels > 0, channels <= 128,
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else {
            throw AudioFailure(message: "The audio interface returned an unsupported input format.")
        }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }
    private static let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6D6C6C70, componentManufacturer: 0x4D614C70, componentFlags: 0, componentFlagsMask: 0)

    func loadFile(_ asset: PlaybackAsset, session: UUID, volume: Float, repeating: Bool) {
        fileGeneration = UUID(); player?.stop()
        file = asset; fileSession = session; filePosition = 0; filePlaying = false; fileScheduled = false
        fileVolume = min(1, max(0, volume)); fileRepeat = repeating
        player?.volume = fileVolume
    }
    func playFile(session: UUID, output: AudioDevice) async throws {
        guard fileSession == session, let file else { return }
        try await waitForConfiguration()
        #if os(macOS)
        guard AudioDevices.alive(output.id), AudioDevices.string(output.id, kAudioDevicePropertyDeviceUID) == output.uid else { throw AudioFailure(message: "The selected output is disconnected. Choose an output in Audio Settings.") }
        #endif
        if self.output?.uid != output.uid || engine == nil {
            self.output = output; filePlaying = false
            configuring = true
            do { try await rebuild(capture: false); configuring = false } catch { configuring = false; throw error }
        }
        guard let engine, let player else { throw AudioFailure(message: "The audio player could not start.") }
        if !engine.isRunning { try MLAudioGraphTools.start(engine) }
        if filePosition >= file.duration { filePosition = 0; fileScheduled = false }
        if !fileScheduled { schedule(from: filePosition, play: true) } else { player.play(); filePlaying = true }
    }
    func pauseFile(session: UUID) {
        guard fileSession == session else { return }
        filePosition = position(); player?.pause(); filePlaying = false
    }
    func stopFile(session: UUID) {
        guard fileSession == session else { return }
        fileGeneration = UUID(); player?.stop(); filePosition = 0; filePlaying = false; fileScheduled = false
    }
    func seekFile(session: UUID, to seconds: Double) {
        guard fileSession == session, let file, seconds.isFinite else { return }
        filePosition = min(file.duration, max(0, seconds))
        if player != nil { schedule(from: filePosition, play: filePlaying) }
    }
    func configureFile(session: UUID, volume: Float, repeating: Bool) {
        guard fileSession == session else { return }
        fileVolume = min(1, max(0, volume)); player?.volume = fileVolume
        if fileRepeat != repeating {
            filePosition = position(); fileRepeat = repeating
            if fileScheduled { schedule(from: filePosition, play: filePlaying) }
        }
    }
    func fileSnapshot(session: UUID) -> FilePlaybackSnapshot? {
        guard fileSession == session, let file else { return nil }
        return FilePlaybackSnapshot(duration: file.duration, position: position(), playing: filePlaying && player?.isPlaying == true)
    }
    func unloadFile(session: UUID? = nil) {
        if let session, fileSession != session { return }
        fileGeneration = UUID(); player?.stop(); file = nil; fileSession = nil; filePlaying = false; filePosition = 0; fileScheduled = false
    }
    private func position() -> Double {
        guard let file else { return 0 }
        guard filePlaying, let player, let time = player.lastRenderTime, let played = player.playerTime(forNodeTime: time) else { return filePosition }
        let seconds = Double(segmentStart + played.sampleTime) / file.file.processingFormat.sampleRate
        return fileRepeat && file.duration > 0 ? seconds.truncatingRemainder(dividingBy: file.duration) : min(file.duration, max(0, seconds))
    }
    private func schedule(from seconds: Double, play: Bool) {
        guard let file, let player else { return }
        fileGeneration = UUID(); let generation = fileGeneration
        player.stop(); fileScheduled = false
        let rate = file.file.processingFormat.sampleRate
        segmentStart = min(file.file.length, max(0, AVAudioFramePosition(seconds * rate)))
        filePosition = Double(segmentStart) / rate
        guard segmentStart < file.file.length else { filePlaying = false; return }
        fileScheduled = true
        enqueue(start: segmentStart, generation: generation)
        if fileRepeat { enqueue(start: 0, generation: generation) }
        filePlaying = play
        if play { player.play() }
    }
    private func enqueue(start: AVAudioFramePosition, generation: UUID) {
        guard let file, let player else { return }
        let repeating = fileRepeat
        player.scheduleSegment(file.file, startingFrame: start, frameCount: AVAudioFrameCount(file.file.length - start), at: nil,
                               completionCallbackType: repeating ? .dataConsumed : .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.fileGeneration == generation else { return }
                if self.fileRepeat { self.enqueue(start: 0, generation: generation) }
                else if let file = self.file { self.filePosition = file.duration; self.filePlaying = false; self.fileScheduled = false }
            }
        }
    }
}
