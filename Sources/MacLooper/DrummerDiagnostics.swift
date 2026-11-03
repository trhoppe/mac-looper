import Foundation
import AVFoundation
import LooperAudioUnit
import LooperCore
import CoreAudioKit
#if os(macOS)
import CoreAudio
#endif

@MainActor enum DrummerDiagnostics {
    // Render the real installed instrument into memory, never into the speakers.
    static func run() async throws {
        let drums = AudioEngineHost.shared.drums
        let priorProcesses = Set(Self.hardwareProcesses().filter(\.output).map(\.pid))
        Self.dumpHardware("before loading")
        await drums.prepare()
        Self.dumpHardware("after loading")
        guard let node = drums.node else { throw AudioFailure(message: drums.error ?? "Pop Drummer was not loaded.") }

        if !CommandLine.arguments.contains("--no-editor") {
            let editor: PluginEditorController? = await withCheckedContinuation { c in
                node.auAudioUnit.requestViewController { c.resume(returning: $0) }
            }
            _ = editor?.view
        }
        Self.dumpHardware("after editor")
        for parameter in node.auAudioUnit.parameterTree?.allParameters ?? [] {
            let names = parameter.valueStrings ?? []
            let index = Int(parameter.value)
            print("Parameter \(parameter.identifier): \(parameter.value), name=\(names.indices.contains(index) ? names[index] : "not in list"), names=\(names.count)")
        }
        if CommandLine.arguments.contains("--factory-groove") {
            for p in node.auAudioUnit.parameterTree?.allParameters ?? [] where p.identifier == "Param_Groove" || p.identifier == "Param_DrumKit" { p.value = p.minValue }
            try await Task.sleep(for: .seconds(1))
        }
        if CommandLine.arguments.contains("--native-driver") { try await runNative(drums: drums, node: node); return }
        let quantum: AVAudioFrameCount = 32
        let rate = 48000.0
        let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: quantum)
        engine.attach(node)
        let gainNode = try await AudioEngineHost.makeDrummerGain()
        let gain = gainNode.auAudioUnit as! MLDrumGainAudioUnit
        engine.attach(gainNode)
        drums.transport.configureSampleRate(rate)
        try MLAudioGraphTools.connect(engine, source: node, sourceBus: 0, destination: gainNode, destinationBus: 0, format: format)
        try MLAudioGraphTools.connect(engine, source: gainNode, sourceBus: 0, destination: engine.mainMixerNode, destinationBus: 0, format: format)
        try MLAudioGraphTools.prepare(engine)
        drums.restoreStateWhenPrepared()
        try MLAudioGraphTools.start(engine)
        Self.dumpHardware("after graph started")
        defer { drums.setPlaying(false); engine.stop(); engine.detach(node) }
        try await Task.sleep(for: .seconds(1))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: quantum)!
        func render(_ blocks: Int) async throws -> Float {
            var peak: Float = 0
            for _ in 0..<blocks {
                buffer.frameLength = quantum
                var error: OSStatus = 0
                let status = engine.manualRenderingBlock(quantum, buffer.mutableAudioBufferList, &error)
                guard status == .success else { throw AudioFailure(message: "Manual plugin render returned \(status.rawValue), error \(error).") }
                try await Task.sleep(for: .microseconds(Int64(Double(quantum) * 1_000_000 / rate)))
                for channel in 0..<2 {
                    for sample in UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)) { peak = max(peak, abs(sample)) }
                }
            }
            return peak
        }
        _ = try await render(100) // Let the AU observe a stopped host before its first Play.
        Self.dumpHardware("after stopped renders")
        drums.tempo = 120; drums.setPlaying(true); gain.volume = 1
        if CommandLine.arguments.contains("--visible-editor") { try await Task.sleep(for: .seconds(2)) }
        let first = try await render(Int(rate * 3) / Int(quantum)), beatAt120 = drums.transport.beatPosition
        drums.tempo = 90
        let second = try await render(Int(rate * 2) / Int(quantum)), beatAt90 = drums.transport.beatPosition
        gain.volume = 0
        _ = try await render(8)
        let mutedPlaying = try await render(100)
        gain.volume = 0.25
        _ = try await render(8)
        let quarter = try await render(1500)
        gain.volume = 1
        _ = try await render(8)
        let restored = try await render(1500)
        drums.setPlaying(false); gain.volume = 0
        _ = try await render(8)
        let stopped = try await render(100)
        print("Pop Drummer: \(node.auAudioUnit.audioUnitName ?? "AUv3") / \(node.auAudioUnit.outputBusses[0].format)")
        print("120 BPM: peak=\(first), beat=\(beatAt120); 90 BPM: peak=\(second), beat=\(beatAt90); stopped peak=\(stopped)")
        print("Host callbacks=\(drums.transport.renderedCallbacks), frames=\(drums.transport.renderedFrames), musical queries=\(drums.transport.musicalQueries), transport queries=\(drums.transport.transportQueries)")
        if let state = node.auAudioUnit.fullState {
            print("Sound module=\(state["soundModule"] ?? "unknown"); groove=\(state["grooveId"] ?? "unknown"); kit=\(state["soundsetId"] ?? "unknown")")
            print("Sync=\(state["enableSync"] ?? "unknown"); play lock=\(state["lockPlay"] ?? "unknown"); padlock=\(state["padlockSelected"] ?? "unknown")")
        }
        print("Volume: zero while playing=\(mutedPlaying), quarter=\(quarter), full=\(restored)")
        let bypassClients = Self.hardwareProcesses().filter { !priorProcesses.contains($0.pid) && $0.output }
        guard bypassClients.isEmpty else { throw AudioFailure(message: "Pop Drummer opened an independent hardware output: \(bypassClients.map(\.pid)).") }
        guard max(first, second) > 0.00001, restored > 0.00001, quarter > 0.00001, quarter < max(first, second, restored) * 0.5,
              mutedPlaying == 0, stopped < 0.00001, abs(beatAt120 - 6) < 0.01, abs(beatAt90 - 9) < 0.01,
              drums.transport.renderedCallbacks > 900, drums.transport.renderedFrames == quantum else {
            throw AudioFailure(message: "Pop Drummer audio or host-sync verification failed.")
        }
        Self.dumpHardware("after playing")
        let customUI: Bool = await withCheckedContinuation { continuation in
            node.auAudioUnit.requestViewController { continuation.resume(returning: $0 != nil) }
        }
        guard customUI else { throw AudioFailure(message: "Pop Drummer did not provide its editor.") }
        if CommandLine.arguments.contains("--save-plugin-state"), CommandLine.arguments.contains("--plugin-state") { drums.saveState() }
        print("PASS: installed Pop Drummer AUv3 renders audio, follows 120 → 90 BPM, stops silently, and supplies its full editor.")
    }
}

extension DrummerDiagnostics {
    static func runNative(drums: PopDrummerModel, node: AVAudioUnit) async throws {
        let engine = AVAudioEngine(), mixer = AVAudioMixerNode()
        let rate: Double
        #if os(macOS)
        guard let output = try AudioDevices.list().first(where: { $0.name == "AM4 Proxy" }) else { throw AudioFailure(message: "Connect AM4 Proxy for the native-driver diagnostic.") }
        try AudioDevices.require32Frames(output.id, name: output.name)
        try engine.outputNode.auAudioUnit.setDeviceID(output.id)
        rate = output.rate
        #else
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(48000); try session.setPreferredIOBufferDuration(32.0 / 48000)
        try session.setActive(true); rate = session.sampleRate
        #endif
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.attach(node); engine.attach(mixer)
        drums.transport.configureSampleRate(rate)
        try MLAudioGraphTools.connect(engine, source: node, sourceBus: 0, destination: mixer, destinationBus: 0, format: format)
        try MLAudioGraphTools.connect(engine, source: mixer, sourceBus: 0, destination: engine.mainMixerNode, destinationBus: 0, format: format)
        try MLAudioGraphTools.connect(engine, source: engine.mainMixerNode, sourceBus: 0, destination: engine.outputNode, destinationBus: 0, format: format)
        // Consume the plugin through our known no-monitoring effect. This keeps
        // the full native graph rendering while guaranteeing silent hardware output.
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x646d7473, componentManufacturer: 0x4D614C70, componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(MLGuitarLoopAudioUnit.self, as: description, name: "Mac Looper: Silent diagnostic", version: 1)
        let sink: AVAudioUnit = try await withCheckedThrowingContinuation { c in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                if let unit { c.resume(returning: unit) } else { c.resume(throwing: error ?? AudioFailure(message: "No diagnostic sink.")) }
            }
        }
        engine.attach(sink)
        engine.disconnectNodeOutput(mixer)
        try MLAudioGraphTools.connect(engine, source: mixer, sourceBus: 0, destination: sink, destinationBus: 0, format: format)
        try MLAudioGraphTools.connect(engine, source: sink, sourceBus: 0, destination: engine.mainMixerNode, destinationBus: 0, format: format)
        engine.mainMixerNode.outputVolume = 1
        let meter = drums.transport
        try MLAudioGraphTools.prepare(engine)
        guard let silentUnit = sink.auAudioUnit as? MLGuitarLoopAudioUnit, let core = silentUnit.core else { throw AudioFailure(message: "No diagnostic input meter.") }
        func collect(_ seconds: Double) async throws -> Float {
            var peak: Float = 0
            for _ in 0..<Int(seconds * 100) {
                peak = max(peak, tl_snapshot(core).peak)
                try await Task.sleep(for: .milliseconds(10))
            }
            return peak
        }
        drums.restoreStateWhenPrepared()
        try MLAudioGraphTools.start(engine)
        defer { drums.setPlaying(false); engine.stop(); engine.detach(node) }
        try await Task.sleep(for: .seconds(1))
        drums.tempo = 120; drums.setPlaying(true)
        let first = try await collect(CommandLine.arguments.contains("--visible-editor") ? 30 : 3), beat1 = meter.beatPosition
        drums.tempo = 90
        let second = try await collect(2), beat2 = meter.beatPosition
        drums.setPlaying(false); mixer.outputVolume = 0
        try await Task.sleep(for: .milliseconds(300))
        let stopped = try await collect(0.3)
        print("Native plugin: peaks=\(first),\(second), beat120=\(beat1), beat90=\(beat2), muted=\(stopped), frames=\(meter.renderedFrames)")
        print("Queries music=\(meter.musicalQueries), transport=\(meter.transportQueries)")
        guard max(first, second) > 0.00001 else { throw AudioFailure(message: "The native plugin driver is silent too.") }
        print("PASS: native AUv3 driver produces drums and advances the host timeline.")
    }
}

private extension DrummerDiagnostics {
    static func hardwareProcesses() -> [(pid: UInt32, output: Bool)] {
        #if os(macOS)
        let processes = (try? AudioDevices.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)) ?? []
        return processes.filter { AudioDevices.string($0, kAudioProcessPropertyBundleID).contains("lumbeat") }.map {
            (AudioDevices.number($0, kAudioProcessPropertyPID, fallback: UInt32(0)),
             AudioDevices.number($0, kAudioProcessPropertyIsRunningOutput, fallback: UInt32(0)) != 0)
        }
        #else
        return []
        #endif
    }
    static func dumpHardware(_ stage: String) {
        print("Plugin hardware \(stage): \(hardwareProcesses().map { "pid=\($0.pid) output=\($0.output)" })")
    }
}
