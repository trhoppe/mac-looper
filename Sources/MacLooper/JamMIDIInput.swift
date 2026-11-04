import CoreMIDI
import Combine
import JamCore

/// Input-only client; independent of the AM4 remote's MIDI connection.
@MainActor final class JamMIDIInput: ObservableObject {
    @Published private(set) var status = "MIDI is off"
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var sources = Set<MIDIEndpointRef>()
    private var generation = UUID()
    private var handler: ((JamMIDIAction) async -> Void)?
    private var pending: [JamMIDIAction] = []
    private var task: Task<Void, Never>?

    func start(handler: @escaping (JamMIDIAction) async -> Void) {
        guard port == 0 else { return }
        self.handler = handler
        generation = UUID(); let token = generation
        if client == 0 {
            let result = MIDIClientCreateWithBlock("Mac Jams Pedals" as CFString, &client) { [weak self] _ in
                Task { @MainActor in self?.refreshSources() }
            }
            guard result == noErr else { status = "MIDI unavailable (\(result))"; return }
        }
        let result = MIDIInputPortCreateWithProtocol(client, "Looper and Drummer" as CFString, ._1_0, &port) { [weak self] list, _ in
            // Event packets are variable-length. Never copy the fixed Swift tuple or
            // index packet structs as an array: valid packets can exceed 64 words.
            var packet = UnsafeRawPointer(list)
                .advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
                .assumingMemoryBound(to: MIDIEventPacket.self)
            var actions: [JamMIDIAction] = []
            for _ in 0..<list.pointee.numPackets {
                let words = UnsafeRawPointer(packet)
                    .advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
                    .assumingMemoryBound(to: UInt32.self)
                actions.append(contentsOf: JamMIDIAction.decode(UnsafeBufferPointer(start: words, count: Int(packet.pointee.wordCount))))
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
            guard !actions.isEmpty else { return }
            let received = actions
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.receive(received)
            }
        }
        guard result == noErr else { status = "MIDI unavailable (\(result))"; return }
        refreshSources()
    }
    private func refreshSources() {
        guard port != 0 else { return }
        let available = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.filter { $0 != 0 })
        for source in sources.subtracting(available) { MIDIPortDisconnectSource(port, source); sources.remove(source) }
        var failed = false
        for source in available.subtracting(sources) {
            if MIDIPortConnectSource(port, source, nil) == noErr { sources.insert(source) } else { failed = true }
        }
        let names = sources.sorted().map { source -> String in
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name) == noErr, let name {
                return name.takeRetainedValue() as String
            }
            return "MIDI input"
        }
        status = names.isEmpty ? "Waiting for a MIDI controller" : names.joined(separator: ", ")
        if failed { status += " · Some MIDI inputs could not connect" }
    }
    private func receive(_ actions: [JamMIDIAction]) {
        // All pedal and UI commands reach the DSP from the main actor (its single
        // queue producer). Await startup in order, rather than racing async presses.
        pending.append(contentsOf: actions)
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            while self.generation == token && !self.pending.isEmpty && !Task.isCancelled {
                let action = self.pending.removeFirst()
                await self.handler?(action)
            }
            if self.generation == token { self.task = nil }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; pending.removeAll(); handler = nil
        if port != 0 { MIDIPortDispose(port); port = 0 }
        sources.removeAll(); status = "MIDI is off"
        // Keep the process-lifetime client: CoreMIDI discourages disposing the last
        // client and creating it again. Disposing the input port stops all delivery.
    }
}
