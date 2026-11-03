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
    let drums: PopDrummerModel
    // An injected output setup lets regression tests render the real graph offline.
    private let playbackSetup: ((AVAudioEngine) throws -> Double)?
    private let makeGain: () async throws -> AVAudioUnit
    init(drums: PopDrummerModel? = nil, playbackSetup: ((AVAudioEngine) throws -> Double)? = nil,
         makeGain: (() async throws -> AVAudioUnit)? = nil) {
        self.drums = drums ?? PopDrummerModel(); self.playbackSetup = playbackSetup
        self.makeGain = makeGain ?? Self.makeDrummerGain
    }
    private var drumGainNode: AVAudioUnit?
    private var drumGain: MLDrumGainAudioUnit?
    private(set) var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var loopNode: AVAudioUnit?
    private(set) var loopUnit: MLGuitarLoopAudioUnit?
    private(set) var captureEnabled = false
    private(set) var sampleRate = 48000.0
    private(set) var actualBufferFrames = 0
    private var output: AudioDevice?
    private var input: AudioDevice?
    private var inputChannel = 0
    let configuration = AudioConfigurationGate()
    private var lifecycle = UUID()
    private(set) var suspended = false
    #if os(iOS)
    private var configuredRoute: [String] = []
    #endif
    #if os(macOS)
    private var aggregate: AudioDeviceID?
    private var macDriver: MLMacAudioDriver?
    #endif
    private var file: PlaybackAsset?
    private var fileSession: UUID?
    private var filePosition = 0.0
    private var filePlaying = false
    private var fileRepeat = false
    private var fileVolume: Float = 1.0
    private var segmentStart: AVAudioFramePosition = 0
    private var fileGeneration = UUID()
    private var fileScheduled = false
    private var fileIntent = UUID()

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
    private func checkLifecycle(_ token: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle == token else { throw CancellationError() }
    }
    func startLoop(input: AudioDevice, output: AudioDevice, channel: Int) async throws {
        let token = lifecycle
        try await configuration.acquire(); defer { configuration.release() }
        try checkLifecycle(token)
        if captureEnabled, isRunning, self.input?.uid == input.uid, self.output?.uid == output.uid, inputChannel == channel { return }
        self.input = input; self.output = output; inputChannel = channel
        let resumeBacking = filePlaying, backingSession = fileSession, backingIntent = fileIntent
        do { try await rebuild(capture: true) }
        catch {
            try checkLifecycle(token)
            let captureError = error
            filePlaying = resumeBacking && fileSession == backingSession && fileIntent == backingIntent
            if file != nil || drums.playing { try? await rebuild(capture: false) }
            throw captureError
        }
    }
    func stopLoop() async {
        do {
            let token = lifecycle
            try await configuration.acquire(); defer { configuration.release() }
            try checkLifecycle(token)
            if captureEnabled {
                if file == nil && !drums.playing { shutdownAudio() }
                else { try await rebuild(capture: false) }
            }
        } catch is CancellationError { } catch { shutdownAudio(); filePlaying = false }
    }
    func shutdown() {
        lifecycle = UUID(); fileIntent = UUID()
        filePlaying = false; drums.setPlaying(false); drums.saveState(); shutdownAudio()
    }
    /// iPad suspension preserves completed samples and cancels capture after
    /// rendering stops. Returning to the app never resumes a transport.
    func suspendAudio() {
        lifecycle = UUID(); fileIntent = UUID(); suspended = true
        filePosition = position(); player?.pause(); filePlaying = false
        drums.setPlaying(false); updateDrummerVolume()
        // iPad lifecycle calls this; offline tests have no physical driver.
        #if os(macOS)
        macDriver?.stop()
        #endif
        engine?.pause()
        if let core { tl_suspend(core) }
        #if os(iOS)
        if playbackSetup == nil { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
        #endif
    }
    func resumeSuspendedAudio() async throws -> Bool {
        guard suspended, let engine else { return false }
        let token = lifecycle
        try await configuration.acquire(); defer { configuration.release() }
        try checkLifecycle(token)
        guard suspended, self.engine === engine else { return false }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)
        if playbackSetup == nil && (Self.currentRoute != configuredRoute || abs(session.sampleRate - sampleRate) >= 0.1) {
            if let core, tl_snapshot(core).state != TL_EMPTY {
                throw AudioFailure(message: "The audio route changed. Your loop is retained. Reconnect the original interface, or Clear the loop before connecting a new route.")
            }
            shutdownAudio()
            return false
        }
        #endif
        try MLAudioGraphTools.prepare(engine)
        try MLAudioGraphTools.start(engine)
        suspended = false
        return true
    }
    #if os(iOS)
    private static var currentRoute: [String] {
        let route = AVAudioSession.sharedInstance().currentRoute
        return route.inputs.map(\.uid) + route.outputs.map(\.uid)
    }
    #endif
    func resetAudioService() {
        lifecycle = UUID(); fileIntent = UUID(); filePlaying = false
        shutdownAudio(); drums.resetAfterAudioServiceReset()
    }
    func updateDrummerVolume() { drumGain?.volume = drums.playing ? Float(drums.volume) : 0 }
    func startDrummer(output: AudioDevice?) async throws {
        guard !suspended else { throw AudioFailure(message: "Audio is paused. Return to Mac Jams and reconnect audio before playing drums.") }
        let token = lifecycle
        guard let output else { throw AudioFailure(message: "Choose an output in Audio Settings before playing drums.") }
        await drums.prepare()
        try checkLifecycle(token)
        try await configuration.acquire(); defer { configuration.release() }
        try checkLifecycle(token)
        guard let node = drums.node else { throw AudioFailure(message: drums.error ?? "Pop Drummer could not load.") }
        if engine == nil || self.output?.uid != output.uid {
            if let core, tl_snapshot(core).state != TL_EMPTY { throw AudioFailure(message: "Keep the current output or clear the guitar loop before changing the drum route.") }
            let capture = captureEnabled
            self.output = output
            try await rebuild(capture: capture)
        } else if let engine, node.engine !== engine {
            // Add only the instrument branch upstream of the mixer. The loop
            // unit, its captured samples, backing schedule and transport survive.
            try await attachPreparedDrummer(to: engine)
            try MLAudioGraphTools.prepare(engine)
            drums.restoreStateWhenPrepared()
        }
        guard let engine, node.engine === engine else { throw AudioFailure(message: drums.error ?? "The drum audio route could not connect.") }
        let previousQueries = drums.transport.transportQueries
        if !engine.isRunning { try MLAudioGraphTools.start(engine) }
        // Lumbeat waits for its own Play if its first render already sees a
        // moving host. Let it observe stopped transport before our first Start.
        for _ in 0..<100 {
            if drums.transport.transportQueries > previousQueries + 1 { return }
            try await Task.sleep(for: .milliseconds(5))
            try checkLifecycle(token)
        }
        throw AudioFailure(message: "Pop Drummer’s audio route isn’t rendering. Retry the audio connection in Settings.")
    }
    func prepareDrummerEditor() async throws {
        try await startDrummer(output: output)
    }
    private func removeDrummer(from engine: AVAudioEngine) {
        if let node = drums.node, node.engine === engine { engine.disconnectNodeOutput(node); engine.detach(node) }
        if let drumGainNode { engine.disconnectNodeOutput(drumGainNode); engine.detach(drumGainNode) }
        drumGainNode = nil; drumGain = nil
    }
    private func shutdownAudio() {
        #if os(macOS)
        macDriver?.stop(); macDriver = nil
        #endif
        engine?.stop(); player?.stop()
        if let engine { removeDrummer(from: engine) }
        suspended = false
        loopUnit = nil; loopNode = nil; player = nil; engine = nil; captureEnabled = false; fileScheduled = false
        #if os(macOS)
        if let aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = nil
        #endif
    }
    private func trace(_ value: String) { if CommandLine.arguments.contains("--smoke-test") { print("Audio: " + value) } }
    private func rebuild(capture: Bool) async throws {
        trace("rebuild capture=\(capture)")
        let token = lifecycle, session = fileSession, intent = fileIntent
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
            if let playbackSetup {
                sampleRate = try playbackSetup(e); actualBufferFrames = 32
            } else if capture {
                guard let input else { throw AudioFailure(message: "Choose an input in Audio Settings.") }
                trace("routing hardware")
                let route = try await AudioDevices.route(input: input, output: output)
                do { try checkLifecycle(token) }
                catch {
                    // The route is still locally owned here. Shutdown may have
                    // run while route creation yielded, before host ownership.
                    if let aggregate = route.aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
                    throw error
                }
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
            if let playbackSetup {
                sampleRate = try playbackSetup(e); actualBufferFrames = 32
            } else {
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
            }
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
                try checkLifecycle(token)
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
            if drums.node != nil {
                do { try await attachPreparedDrummer(to: e) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try checkLifecycle(token)
                    removeDrummer(from: e); drums.error = "Pop Drummer couldn’t connect: " + error.localizedDescription
                }
            }
            try checkLifecycle(token)
            trace("prepare graph")
            do { try MLAudioGraphTools.prepare(e) }
            catch {
                guard drumGainNode != nil else { throw error }
                removeDrummer(from: e); drums.error = "Pop Drummer couldn’t prepare: " + error.localizedDescription
                try MLAudioGraphTools.prepare(e)
            }
            if drums.node?.engine === e { drums.restoreStateWhenPrepared() }
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
            #if os(iOS)
            configuredRoute = Self.currentRoute
            #endif
            let stillPlaying = resume && session == fileSession && intent == fileIntent && filePlaying
            filePlaying = stillPlaying
            if file != nil { schedule(from: filePosition, play: stillPlaying) }
            p.volume = fileVolume
        } catch {
            if self.engine === e { shutdownAudio(); filePlaying = false }
            throw error
        }
    }
    func attachPreparedDrummer(to engine: AVAudioEngine) async throws {
        guard let node = drums.node, node.engine !== engine else { return }
        let token = lifecycle
        let gain = try await makeGain()
        try checkLifecycle(token)
        guard self.engine === engine else { throw CancellationError() }
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        do {
            drumGainNode = gain; drumGain = gain.auAudioUnit as? MLDrumGainAudioUnit
            engine.attach(node); engine.attach(gain)
            drums.transport.configureSampleRate(sampleRate)
            try MLAudioGraphTools.connect(engine, source: node, sourceBus: 0, destination: gain, destinationBus: 0, format: stereo)
            try MLAudioGraphTools.connect(engine, source: gain, sourceBus: 0, destination: engine.mainMixerNode, destinationBus: 2, format: stereo)
            updateDrummerVolume()
        } catch { removeDrummer(from: engine); throw error }
    }
    private static var gainRegistered = false
    static func makeDrummerGain() async throws -> AVAudioUnit {
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x64676169,
            componentManufacturer: 0x4D614C70, componentFlags: 0, componentFlagsMask: 0)
        if !gainRegistered {
            AUAudioUnit.registerSubclass(MLDrumGainAudioUnit.self, as: d, name: "Mac Looper: Drum gain", version: 1)
            gainRegistered = true
        }
        return try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: d, options: []) { unit, error in
                if let unit { continuation.resume(returning: unit) }
                else { continuation.resume(throwing: error ?? AudioFailure(message: "Could not create the drum volume control.")) }
            }
        }
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
        fileIntent = UUID(); fileGeneration = UUID(); player?.stop()
        file = asset; fileSession = session; filePosition = 0; filePlaying = false; fileScheduled = false
        fileVolume = min(1, max(0, volume)); fileRepeat = repeating
        player?.volume = fileVolume
    }
    func requestFilePlay(session: UUID) -> UUID? {
        guard !suspended, fileSession == session, file != nil else { return nil }
        fileIntent = UUID(); return fileIntent
    }
    func playFile(session: UUID, output: AudioDevice, requestedIntent: UUID? = nil) async throws {
        guard !suspended, fileSession == session, file != nil else { return }
        if let requestedIntent { guard fileIntent == requestedIntent else { return } }
        else { fileIntent = UUID() }
        let intent = fileIntent, token = lifecycle
        func current() -> Bool { fileSession == session && fileIntent == intent && lifecycle == token && !Task.isCancelled }
        do {
            try await configuration.acquire(); defer { configuration.release() }
            guard current() else { return }
            #if os(macOS)
            if playbackSetup == nil {
                guard AudioDevices.alive(output.id), AudioDevices.string(output.id, kAudioDevicePropertyDeviceUID) == output.uid else { throw AudioFailure(message: "The selected output is disconnected. Choose an output in Audio Settings.") }
            }
            #else
            guard playbackSetup != nil || output.uid == "ios-system-output" else { throw AudioFailure(message: "Choose an available output in Audio Settings.") }
            #endif
            if self.output?.uid != output.uid || engine == nil {
                self.output = output; filePlaying = false
                try await rebuild(capture: false)
                guard current() else { return }
            }
            guard let engine, let player, let file else { throw AudioFailure(message: "The audio player could not start.") }
            if !engine.isRunning { try MLAudioGraphTools.start(engine) }
            if filePosition >= file.duration { filePosition = 0; fileScheduled = false }
            if !fileScheduled { schedule(from: filePosition, play: true) } else { player.play(); filePlaying = true }
        } catch {
            // A failure from an obsolete Play must not become the new track's error.
            guard current() else { return }
            throw error
        }
    }
    func pauseFile(session: UUID) {
        guard fileSession == session else { return }
        fileIntent = UUID(); filePosition = position(); player?.pause(); filePlaying = false
    }
    func stopFile(session: UUID) {
        guard fileSession == session else { return }
        fileIntent = UUID(); fileGeneration = UUID(); player?.stop(); filePosition = 0; filePlaying = false; fileScheduled = false
    }
    func seekFile(session: UUID, to seconds: Double) {
        guard fileSession == session, let file, seconds.isFinite else { return }
        filePosition = min(file.duration, max(0, seconds))
        if player != nil, engine?.isRunning == true { schedule(from: filePosition, play: filePlaying) }
        else { fileScheduled = false }
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
        fileIntent = UUID(); fileGeneration = UUID(); player?.stop(); file = nil; fileSession = nil; filePlaying = false; filePosition = 0; fileScheduled = false
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
