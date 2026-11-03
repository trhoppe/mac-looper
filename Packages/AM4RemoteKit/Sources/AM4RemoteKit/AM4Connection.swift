import Foundation
import Combine
import CoreMIDI
#if AM4_SIMULATOR_HELPER
import Network
#endif

@MainActor
final class AM4Connection: ObservableObject {
    @Published private(set) var status = "Connecting to AM4…"
    @Published private(set) var isConnected = false
    @Published private(set) var snapshot: AM4Snapshot?
    @Published private(set) var location: Int?
    @Published private(set) var presets: [AM4Preset] = []
    @Published private(set) var isLoadingPresets = false
    @Published private(set) var log: [String] = []
    @Published private(set) var helperStatus = ""
    @Published private(set) var amp: AM4AmpState?
    @Published private(set) var effectControls: AM4EffectControls?
    private var effectResetValue: AM4ParameterValue?
    private(set) var effectPage: AM4EffectPageSelection?
    @Published private(set) var ampControls: AM4AmpControls?
    @Published private(set) var isNavigating = false
    @Published private(set) var navigationStatus = ""
    @Published private(set) var blocks: AM4BlocksState?
    @Published private(set) var blockStatus = ""
    @Published private(set) var usbPlayback: AM4USBPlaybackLevel?
    @Published private(set) var usbPlaybackStatus = ""
    private var ampResetValue: AM4ParameterValue?
    private(set) var ampPage: String?
    private var inspectedAmpPages = false
    private var inspectedLibraryBanks = false
    @Published private(set) var gainStatus = ""
    @Published private(set) var isApplyingGain = false

    @Published private(set) var hasUnsavedPresetChanges = false
    @Published private(set) var isSavingPreset = false
    @Published private(set) var presetSaveStatus = ""
    private var lastPresetEdit: TimeInterval?
    private var helperSupportsPresetSave = false
    var canSavePreset: Bool {
        let idle = isConnected && !isLoadingPresets && !isApplyingGain && !isNavigating && !isSavingPreset && hasUnsavedPresetChanges
        #if targetEnvironment(simulator)
        return idle && helperSupportsPresetSave
        #else
        return idle
        #endif
    }

    static var transportLabel: String {
        #if targetEnvironment(simulator)
        return "Mac helper"
        #else
        return "USB"
        #endif
    }

    var pollingEnabled = true

    private var client: MIDIClientRef = 0
    private var input: MIDIPortRef = 0
    private var output: MIDIPortRef = 0
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    private var stream = SysExStream()
    private var session = UUID()
    private var timeout: Task<Void, Never>?
    private var nameTimeout: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var catalog = AM4PresetCatalog()
    private var scanStarted = false
    private var refreshTask: Task<Void, Never>?
    private var queryTimeout: Task<Void, Never>?
    private var pendingQuery: (id: UUID, matches: (AM4Message) -> Bool,
                               continuation: CheckedContinuation<AM4Message, Error>)?
    #if AM4_SIMULATOR_HELPER
    private var helper: AM4LocalHelper?
    #endif

    func start() {
        guard worker == nil else { return }
        #if targetEnvironment(simulator)
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.pollingEnabled { await self.readHelper() }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        #else
        #if AM4_SIMULATOR_HELPER
        let server = AM4LocalHelper(state: { [weak self] in self?.deviceState },
                                    setGain: { [weak self] command in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.changeGain(command)
            return self.deviceState
        }, selectPage: { [weak self] page in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            await self.showAmpPage(page)
            return self.deviceState
        }, editAmp: { [weak self] edit in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.changeAmpParameter(edit)
            return self.deviceState
        }, selectAmp: { [weak self] command in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.selectAmp(command)
            return self.deviceState
        }, selectEffectPage: { [weak self] selection in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.showEffectPage(selection)
            return self.deviceState
        }, editEffect: { [weak self] edit in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.changeEffectParameter(edit)
            return self.deviceState
        }, selectEffect: { [weak self] command in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.selectEffect(command)
            return self.deviceState
        }, navigate: { [weak self] command in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.navigate(command)
            return self.deviceState
        }, bypassBlock: { [weak self] command in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.changeBlockBypass(command)
            return self.deviceState
        }, setUSBPlayback: { [weak self] command in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.changeUSBPlayback(command)
            return self.deviceState
        }, savePreset: { [weak self] command in
            guard let self else { throw ConnectionError.message("Helper is unavailable.") }
            try await self.savePreset(command)
            return self.deviceState
        })
        helper = server
        server.onStatus = { [weak self] in self?.helperStatus = $0 }
        server.start()
        #endif
        connectUSB()
        worker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.pollingEnabled else { continue }
                if self.source == 0 { self.connectUSB() }
                else if self.isConnected, !self.isLoadingPresets, !self.isApplyingGain, !self.isNavigating { self.refreshUSB() }
            }
        }
        #endif
    }

    func retry() {
        #if AM4_SIMULATOR_HELPER
        // Keep the listener alive so the simulator can observe reconnection.
        if worker != nil { connectUSB(); return }
        #endif
        stop()
        start()
    }

    func stop() {
        worker?.cancel()
        worker = nil
        #if AM4_SIMULATOR_HELPER
        helper?.stop()
        helper = nil
        helperStatus = ""
        #endif
        disconnectUSB()
    }

    var deviceState: AM4DeviceState {
        AM4DeviceState(version: 9, status: status, connected: isConnected,
                       loadingPresets: isLoadingPresets, location: location,
                       snapshot: snapshot, presets: presets, amp: amp, ampControls: ampControls, effectControls: effectControls, effectResetValue: effectResetValue, ampResetValue: ampResetValue, blocks: blocks, blockStatus: blockStatus, usbPlayback: usbPlayback, usbPlaybackStatus: usbPlaybackStatus,
                       navigationStatus: navigationStatus, navigationBusy: isNavigating, gainStatus: gainStatus, gainBusy: isApplyingGain, presetEdited: hasUnsavedPresetChanges,
                       presetSaveSupported: true, presetSaveBusy: isSavingPreset, presetSaveStatus: presetSaveStatus)
    }

    private func connectUSB() {
        disconnectUSB()
        log = []
        status = "Looking for AM4…"
        let token = session
        do {
            // Keep the client alive for the process lifetime, including while
            // no USB device is attached. Apple's SDK warns that disposing the
            // last client can make later client creation fail in this process.
            if client == 0 {
                let result = MIDIClientCreateWithBlock("AM4 Remote" as CFString, &client) { [weak self] _ in
                    Task { @MainActor in self?.checkConnection() }
                }
                try check(result, operation: "Create MIDI client")
            }
            try check(MIDIInputPortCreateWithBlock(client, "AM4 input" as CFString, &input) { [weak self] list, _ in
                var packet = UnsafeRawPointer(list).advanced(by:
                    MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
                var bytes: [UInt8] = []
                for _ in 0..<list.pointee.numPackets {
                    let data = UnsafeRawPointer(packet).advanced(by:
                        MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to: UInt8.self)
                    bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(packet.pointee.length)))
                    packet = UnsafePointer(MIDIPacketNext(packet))
                }
                let received = bytes
                Task { @MainActor in
                    guard let self, self.session == token else { return }
                    self.receive(received)
                }
            }, operation: "Create MIDI input port")
            try check(MIDIOutputPortCreate(client, "AM4 output" as CFString, &output),
                      operation: "Create MIDI output port")
            let sources = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
            let destinations = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
            append("MIDI inputs: " + (sources.isEmpty ? "none" : sources.map(Self.name).joined(separator: ", ")))
            append("MIDI outputs: " + (destinations.isEmpty ? "none" : destinations.map(Self.name).joined(separator: ", ")))
            guard let pair = sources.compactMap({ source -> (MIDIEndpointRef, MIDIEndpointRef)? in
                guard Self.name(source).localizedCaseInsensitiveContains("AM4") else { return nil }
                var entity: MIDIEntityRef = 0
                guard MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0 else { return nil }
                guard let target = destinations.first(where: { destination in
                    var targetEntity: MIDIEntityRef = 0
                    return MIDIEndpointGetEntity(destination, &targetEntity) == noErr && targetEntity == entity
                }) else { return nil }
                return (source, target)
            }).first else {
                throw ConnectionError.message("AM4 not found. Connect it over USB; retrying automatically.")
            }
            source = pair.0
            destination = pair.1
            try check(MIDIPortConnectSource(input, source, nil), operation: "Connect AM4 MIDI input")
            status = "Waiting for AM4…"
            try send(AM4Message.firmwareRequest)
            try send(AM4Message.locationRequest)
            try send(AM4Message.snapshotRequest)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, self.session == token,
                      self.snapshot == nil || self.location == nil else { return }
                self.disconnectUSB()
                self.status = "No complete AM4 response. Close AM4-Edit; retrying automatically."
            }
        } catch {
            disconnectUSB()
            status = error.localizedDescription
            append(status)
        }
    }

    private func refreshUSB() {
        guard isConnected, refreshTask == nil, !isApplyingGain, !isNavigating, !isLoadingPresets else { return }
        let token = session
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.session == token { self.refreshTask = nil } }
            do {
                do { _ = try await self.readUSBPlayback() }
                catch {
                    self.usbPlayback = nil
                    self.usbPlaybackStatus = error.localizedDescription
                }
                do { _ = try await self.readBlocksUSB() }
                catch {
                    self.blocks = nil
                    self.blockStatus = error.localizedDescription
                }
                _ = try await self.readAmpUSB()
                if ProcessInfo.processInfo.arguments.contains("--library-bank-diagnostics"), !self.inspectedLibraryBanks, let context = self.amp?.context {
                    self.inspectedLibraryBanks = true
                    for block in [58, 62] {
                        let bank = try await self.readEffectBankUSB(block)
                        let values = bank.words.map(String.init).joined(separator: ",")
                        print("[LIBBANK] block=\(block) channel=\(context.channel ?? -1) words=[\(values)]")
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--amp-page-diagnostics"), !self.inspectedAmpPages {
                    self.inspectedAmpPages = true
                    for page in AM4AmpCatalog.shared.pages {
                        self.ampPage = page.id
                        do {
                            let state = try await self.readAmpControlsUSB(page: page.id)
                            let data = try JSONEncoder().encode(state)
                            print("[AMPPAGE] " + String(decoding: data, as: UTF8.self))
                        } catch { print("[AMPPAGE-ERROR] \(page.id): \(error.localizedDescription)") }
                    }
                    self.ampPage = nil
                    print("[AMPPAGE-DONE]")
                }
                if let selection = self.effectPage { _ = try await self.readEffectControlsUSB(selection) }
                else if let page = self.ampPage { _ = try await self.readAmpControlsUSB(page: page) }
            }
            catch {
                guard self.session == token, !Task.isCancelled else { return }
                self.amp = nil
                self.ampControls = nil
                self.effectControls = nil
                self.gainStatus = error.localizedDescription
            }
        }
    }

    /// Every query is serialized; an echoed write never verifies a value.
    private func query(_ bytes: [UInt8], timeoutNanoseconds: UInt64 = 1_500_000_000, matches: @escaping (AM4Message) -> Bool) async throws -> AM4Message {
        try Task.checkCancellation()
        guard pendingQuery == nil else { throw ConnectionError.message("Another AM4 read is in progress.") }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            pendingQuery = (id, matches, continuation)
            do { try send(bytes) }
            catch { finishQuery(.failure(error)); return }
            queryTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled, let self, self.pendingQuery?.id == id else { return }
                self.finishQuery(.failure(ConnectionError.message("AM4 read timed out. Try Refresh.")))
            }
        }
    }

    private func finishQuery(_ result: Result<AM4Message, Error>) {
        let pending = pendingQuery
        pendingQuery = nil
        queryTimeout?.cancel(); queryTimeout = nil
        pending?.continuation.resume(with: result)
    }

    private func readAmpUSB() async throws -> AM4AmpState? {
        let firstLocation = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
        let firstSnapshot = try await query(AM4Message.snapshotRequest) { $0.snapshot != nil }.snapshot!
        guard firstSnapshot.blockIDs.contains(0x3A) else { amp = nil; return nil }
        let firstChannel = try await readAmpChannelUSB()
        let gain = try await query(AM4Message.ampGainRequest) { $0.ampGain != nil }.ampGain!
        let lastLocation = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
        let lastSnapshot = try await query(AM4Message.snapshotRequest) { $0.snapshot != nil }.snapshot!
        let lastChannel = try await readAmpChannelUSB()
        guard firstChannel == lastChannel, firstLocation == lastLocation, firstSnapshot.scene == lastSnapshot.scene,
              firstSnapshot.blockIDs == lastSnapshot.blockIDs else {
            amp = nil
            throw ConnectionError.message("Preset or scene changed. Refresh Gain before editing.")
        }
        let state = AM4AmpState(context: AM4AmpContext(location: lastLocation, scene: lastSnapshot.scene,
                                                       blocks: lastSnapshot.blockIDs, channel: lastChannel), gain: gain)
        if amp != state {
            append("Active Amp Gain: \(String(format: "%.2f", state.gain)) at \(AM4Message.locationLabel(state.context.location)), scene \(state.context.scene + 1).")
            if !isApplyingGain { gainStatus = "Read from AM4" }
        }
        amp = state
        return state
    }

    func refreshGain() {
        #if targetEnvironment(simulator)
        Task { await readHelper() }
        #else
        refreshUSB()
        #endif
    }

    func changeGain(_ command: AM4GainCommand) async throws {
        guard command.isValid else { throw ConnectionError.message("Gain must be between 0 and 10.") }
        guard isConnected, !isApplyingGain, !isNavigating else { throw ConnectionError.message("Wait for the AM4 connection.") }
        isApplyingGain = true
        gainStatus = "Checking current amp…"
        defer { isApplyingGain = false }
        do {
            #if targetEnvironment(simulator)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:32174/amp/gain")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("AM4Remote/2", forHTTPHeaderField: "X-AM4-Client")
            request.httpBody = try JSONEncoder().encode(command)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let failure = try? JSONDecoder().decode(AM4ControlError.self, from: data)
                throw ConnectionError.message(failure?.message ?? "The helper could not verify the gain change.")
            }
            let state = try JSONDecoder().decode(AM4DeviceState.self, from: data)
            guard state.isValid, let confirmed = state.amp,
                  confirmed.context == command.expected.context,
                  abs(confirmed.gain - command.gain) <= 0.005 else {
                throw ConnectionError.message("Gain change was not verified. Refresh before trying again.")
            }
            amp = confirmed
            gainStatus = "Verified on AM4 · not saved"
            #else
            await refreshTask?.value
            guard isConnected, let current = try await readAmpUSB(), current.matches(command.expected) else {
                throw ConnectionError.message("The current amp changed. Review its Gain and try again.")
            }
            if abs(current.gain - command.gain) <= 0.005 {
                gainStatus = "Already set on AM4"
                return
            }
            gainStatus = "Applying Gain…"
            try send(AM4Message.ampGainWrite(command.gain)!)
            for attempt in 0..<3 {
                guard let confirmed = try await readAmpUSB(), confirmed.context == command.expected.context else {
                    throw ConnectionError.message("Preset or scene changed during the edit. Refresh Gain.")
                }
                if abs(confirmed.gain - command.gain) <= 0.005 {
                    gainStatus = "Verified on AM4 · not saved"
                    append("Gain verified: \(String(format: "%.2f", confirmed.gain)) at \(AM4Message.locationLabel(confirmed.context.location)), scene \(confirmed.context.scene + 1).")
                    return
                }
                if attempt < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            throw ConnectionError.message("AM4 returned a different Gain value. Review the current value before retrying.")
            #endif
        } catch {
            gainStatus = error.localizedDescription
            append("Gain edit: " + gainStatus)
            throw error
        }
    }

    func clearPageSubscriptions() {
        ampPage = nil; ampControls = nil
        effectPage = nil; effectControls = nil
        // Do not cancel refreshTask/pendingQuery: in-flight verification owns them.
    }

    /// Only the visible Amp page is polled; the rest of the editor costs no
    /// extra USB traffic. Closing the sheet returns to preset/scene polling.
    func showAmpPage(_ page: String?) async {
        // Clearing a subscription is UI cleanup, not a hardware operation.
        // It must remain possible while a verified edit/navigation finishes.
        guard page == nil || (AM4AmpCatalog.shared.page(page!) != nil && !isApplyingGain && !isNavigating) else { return }
        if page != nil { effectPage = nil; effectControls = nil }
        ampPage = page
        ampControls = nil
        #if targetEnvironment(simulator)
        do {
            _ = try await helperRequest(path: "/amp/page", body: JSONEncoder().encode(AM4PageSelection(page: page)))
            await readHelper()
        } catch { gainStatus = error.localizedDescription }
        #else
        await refreshTask?.value
        guard let page, ampPage == page else { return }
        refreshUSB()
        await refreshTask?.value
        #endif
    }

    private func readParameter(_ key: String) async throws -> AM4ParameterValue {
        guard let definition = AM4AmpCatalog.shared.definition(key) else {
            throw ConnectionError.message("Unknown Amp control.")
        }
        let reply = try await query(AM4Message.parameterRequest(definition)) { $0.isParameterResponse(definition) }
        guard let value = reply.parameterValue(definition) else {
            if ProcessInfo.processInfo.arguments.contains("--amp-page-diagnostics") {
                let raw = AM4Message.unpack(Array(reply.payload.dropFirst(10)), count: 40) ?? []
                print("[AMPINVALID] \(definition.symbol) \(raw.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
            throw ConnectionError.message("AM4 returned an unavailable value. Try refreshing the controls.")
        }
        return value
    }

    private func readAmpChannelUSB() async throws -> Int {
        for _ in 0..<4 {
            let response = try await query(AM4Message.ampChannelRequest) { $0.isAmpChannelReply }
            if let channel = response.ampChannel { return channel }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw ConnectionError.message("The Amp channel is changing. Try again once it settles.")
    }

    private func readEffectBankUSB(_ block: Int) async throws -> AM4EffectBank {
        var reader = AM4EffectBankReader(block: block)
        _ = try await query(AM4Message.request(function: 0x1F, payload: [UInt8(block), 0])) { message in
            reader.receive(message)
            return reader.completed
        }
        guard let bank = reader.bank else { throw ConnectionError.message("AM4 returned an incomplete Amp library bank.") }
        return bank
    }

    private func loadAmpLibraryUSB(_ entry: AM4AmpLibraryEntry, context: AM4AmpContext) async throws {
        guard let file = entry.blockFile, let channel = context.channel, file.banks.count == 2 else {
            throw ConnectionError.message("This library entry is not a supported AM4 Amp preset.")
        }
        var prepared: [AM4EffectBank] = []
        for source in file.banks {
            guard try await readContext() == context else { throw ConnectionError.message("Amp channel changed before library loading.") }
            append("Library \(entry.name): reading block \(source.block), channel \(channel).")
            let original = try await readEffectBankUSB(source.block)
            guard let merged = original.merging(source, from: file.sourceChannel, into: channel) else {
                throw ConnectionError.message("This library file needs conversion for the AM4's firmware.")
            }
            prepared.append(merged)
        }
        // Load both linked banks before confirming either: the Cab can change
        // the Amp's automatic speaker impedance coefficients.
        for merged in prepared {
            guard try await readContext() == context else { throw ConnectionError.message("Amp channel changed before library loading.") }
            // Preserve the editor's handshake/ack sequence; never fire a burst
            // of bulk frames or resend an unacknowledged partial transaction.
            // Cab's marker can have no reply when the desktop editor is not
            // attached. It is not a data acknowledgment. Keep the captured
            // marker→start order and verify all actual transfer frames below.
            try send(AM4Message.libraryTransferMode(block: merged.block)!)
            try await Task.sleep(nanoseconds: 5_000_000)
            for frame in merged.frames {
                let function = frame[5]
                append("Library block \(merged.block): sending 0x\(String(function, radix: 16)), \(frame.count) bytes.")
                let ack = try await query(frame) { $0.function == 0x64 && $0.payload.first == function }
                guard ack.payload == [function, 0] else { throw ConnectionError.message("AM4 rejected the library transfer. Refresh before retrying.") }
            }
        }
        for merged in prepared {
            // The end ACK accepts the bank; DSP-dependent values can settle
            // afterward. Verify a settled snapshot instead of the first reply.
            try await Task.sleep(nanoseconds: 200_000_000)
            var actual = try await readEffectBankUSB(merged.block)
            if merged.block == 62, actual.words.count == merged.words.count, !merged.matchesLoaded(actual, channel: channel) {
                // Bulk import can retain the previous runtime Cab Blend.
                // Apply its saved complementary pair through the ordinary
                // parameter setter, then verify the resulting full bank.
                let base = channel * merged.stride
                let differences = merged.words.indices.filter { merged.words[$0] != actual.words[$0] }
                if differences.allSatisfy({ $0 == base + 75 || $0 == base + 76 }) {
                    guard try await readContext() == context else { throw ConnectionError.message("Amp channel changed during library loading.") }
                    for parameter in [75, 76] {
                        let definition = AM4AmpCatalog.shared.definition("62:\(parameter)")!
                        let bits = Float(Double(merged.words[base + parameter]) / 65534).bitPattern
                        try send(AM4Message.parameterFrame(definition, action: 2,
                            raw: (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }))
                        try await Task.sleep(nanoseconds: 30_000_000)
                    }
                }
            }
            for delay in [UInt64(150_000_000), 300_000_000, 600_000_000, 1_000_000_000] {
                if merged.matchesLoaded(actual, channel: channel) { break }
                try await Task.sleep(nanoseconds: delay)
                actual = try await readEffectBankUSB(merged.block)
            }
            let afterContext = try await readContext()
            if afterContext != context || !merged.matchesLoaded(actual, channel: channel) {
                let differences = zip(merged.words, actual.words).enumerated().filter { $0.element.0 != $0.element.1 }
                    .prefix(20).map { "\($0.offset):\($0.element.0)→\($0.element.1)" }.joined(separator: ",")
                append("Library bank mismatch block=\(merged.block), channel=\(channel), expectedWords=\(merged.words.count), actualWords=\(actual.words.count), context=\(afterContext == context), diff=[\(differences)]")
                throw ConnectionError.message("Library read-back differs. Refresh the Amp before retrying.")
            }
        }
    }

    private func readContext() async throws -> AM4AmpContext {
        let location = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
        let snapshot = try await query(AM4Message.snapshotRequest) { $0.snapshot != nil }.snapshot!
        let channel = try await readAmpChannelUSB()
        let context = AM4AmpContext(location: location, scene: snapshot.scene, blocks: snapshot.blockIDs, channel: channel)
        guard context.isValid else { throw ConnectionError.message("The current preset has no Amp block.") }
        return context
    }

    private func readAmpControlsUSB(page: String) async throws -> AM4AmpControls {
        let catalog = AM4AmpCatalog.shared
        guard let layout = catalog.page(page) else { throw ConnectionError.message("Unknown Amp page.") }
        let first = try await readContext()
        var values: [String: AM4ParameterValue] = ["58:10": try await readParameter("58:10")]
        guard Int(values["58:10"]!.raw) < catalog.models.count else {
            throw ConnectionError.message("This amp model needs updated control definitions.")
        }
        // First remove other models' variants. Then read only gates used by
        // the remaining rows, before resolving all of their visibility rules.
        let candidates = layout.controls.filter { control in
            control.conditions.filter { $0.key == "58:10" }.allSatisfy { $0.matches(values) }
        }
        let dependencies = Set(candidates.flatMap { $0.conditions.map(\.key) }).subtracting(["58:10"])
        for key in dependencies.sorted() { values[key] = try await readParameter(key) }
        let visible = catalog.controls(page: page, values: values)
        for key in Set(visible.map(\.key)).sorted() where values[key] == nil {
            values[key] = try await readParameter(key)
        }
        // Recheck visibility gates and context after the batch, so a model,
        // mode, scene, or preset change cannot publish a mixed set of controls.
        for key in dependencies.sorted() {
            guard let previous = values[key], try await readParameter(key).matches(previous) else {
                throw ConnectionError.message("Amp options changed while reading. Refreshing…")
            }
        }
        let lastModel = try await readParameter("58:10")
        let last = try await readContext()
        guard first == last, lastModel.raw == values["58:10"]?.raw else {
            ampControls = nil
            throw ConnectionError.message("Preset, scene, or amp model changed. Refreshing…")
        }
        let state = AM4AmpControls(context: last, model: Int(lastModel.raw), modelName: lastModel.text,
                                   page: page, values: values)
        guard state.isValid else { throw ConnectionError.message("AM4 returned invalid Amp controls.") }
        if ampPage == page {
            let changed = ampControls?.model != state.model || ampControls?.page != page || ampControls?.context != state.context
            ampControls = state
            if changed {
                append("Amp controls: \(state.modelName), \(page), \(visible.count) controls at \(AM4Message.locationLabel(last.location)).")
                if !isApplyingGain { gainStatus = "Read from AM4" }
            }
        }
        return state
    }

    func selectAmp(_ command: AM4AmpSelection) async throws {
        guard command.isValid, isConnected, !isApplyingGain, !isNavigating, !isLoadingPresets,
              let page = ampPage else {
            throw ConnectionError.message("Wait for the Amp controls to finish loading.")
        }
        isApplyingGain = true
        ampResetValue = nil
        gainStatus = command.model == nil ? "Loading Amp library preset…" : "Changing amp type…"
        defer { isApplyingGain = false }
        do {
            #if targetEnvironment(simulator)
            let state = try await helperRequest(path: "/amp/select", body: JSONEncoder().encode(command))
            guard let confirmed = state.ampControls, confirmed.context.location == command.context.location, confirmed.context.scene == command.context.scene,
                  confirmed.context.blocks == command.context.blocks, confirmed.context.channel == (command.channel ?? command.context.channel),
                  command.model == nil || confirmed.model == command.model else {
                throw ConnectionError.message("The helper did not verify the Amp selection.")
            }
            ampControls = confirmed
            amp = state.amp
            blocks = state.blocks
            gainStatus = state.gainStatus
            #else
            await refreshTask?.value
            let current = try await readAmpControlsUSB(page: page)
            guard current.context == command.context, current.model == command.expectedModel else {
                throw ConnectionError.message("The active amp changed. Review its type and try again.")
            }
            if let channel = command.channel {
                if current.context.channel == channel { gainStatus = "Already on channel " + String(UnicodeScalar(65 + channel)!); return }
                try send(AM4Message.ampChannelWrite(channel)!)
                var verified = false
                for _ in 0..<5 {
                    if try await readAmpChannelUSB() == channel { verified = true; break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard verified else { throw ConnectionError.message("AM4 did not confirm the channel switch.") }
            } else if let model = command.model {
                if model == current.model { gainStatus = "Already set on AM4"; return }
                try send(AM4Message.ampModelWrite(command)!)
                var verified = false
                for attempt in 0..<5 {
                    if attempt > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
                    let actual = try await readParameter("58:10")
                    if actual.raw == UInt32(model) { verified = true; break }
                }
                guard verified else { throw ConnectionError.message("AM4 did not confirm the selected amp type.") }
            } else if let id = command.libraryID, let entry = AM4AmpLibrary.shared.entry(id) {
                try await loadAmpLibraryUSB(entry, context: current.context)
            }
            ampControls = nil
            let confirmed = try await readAmpControlsUSB(page: page)
            guard confirmed.context.location == command.context.location, confirmed.context.scene == command.context.scene,
                  confirmed.context.blocks == command.context.blocks, confirmed.context.channel == (command.channel ?? command.context.channel),
                  command.model == nil || confirmed.model == command.model else {
                ampControls = nil
                throw ConnectionError.message("The amp or scene changed during loading. Refresh its controls.")
            }
            _ = try await readAmpUSB()
            _ = try await readBlocksUSB()
            gainStatus = "Verified on AM4 · not saved"
            append("Amp selection verified: \(confirmed.modelName), channel=\(confirmed.context.channel ?? -1), operation=\(command.libraryID != nil ? "library" : command.channel != nil ? "channel" : "type")")
            #endif
        } catch {
            ampControls = nil
            gainStatus = error.localizedDescription
            append("Amp selection: " + gainStatus)
            throw error
        }
    }

    func changeAmpParameter(_ edit: AM4AmpEdit) async throws {
        guard edit.isValid, isConnected, !isApplyingGain, !isNavigating, !isLoadingPresets else {
            throw ConnectionError.message("Wait for the Amp controls to finish loading.")
        }
        isApplyingGain = true
        gainStatus = "Checking current amp…"
        ampResetValue = nil
        defer { isApplyingGain = false }
        do {
            #if targetEnvironment(simulator)
            let state = try await helperRequest(path: "/amp/parameter", body: JSONEncoder().encode(edit))
            guard let confirmed = state.ampControls, confirmed.context == edit.context, confirmed.model == edit.model,
                  let actual = confirmed.values[edit.key], edit.isConfirmed(by: actual, resetResult: state.ampResetValue) else {
                throw ConnectionError.message("The helper did not verify this Amp value. Refresh before retrying.")
            }
            ampControls = confirmed
            ampResetValue = state.ampResetValue
            gainStatus = state.gainStatus
            #else
            await refreshTask?.value
            guard ampPage == edit.page else { throw ConnectionError.message("The Amp page changed. Try again.") }
            let current = try await readAmpControlsUSB(page: edit.page)
            let catalog = AM4AmpCatalog.shared
            guard current.context == edit.context, current.model == edit.model,
                  let previous = current.values[edit.key], previous.matches(edit.expected),
                  catalog.controls(page: edit.page, values: current.values).contains(where: { $0.key == edit.key }),
                  let definition = catalog.definition(edit.key) else {
                throw ConnectionError.message("The amp or this control changed. Review its current value and try again.")
            }
            if let normalized = edit.normalized, abs(previous.normalized - normalized) <= definition.tolerance(at: normalized) {
                gainStatus = "Already set on AM4"; return
            }
            if let ordinal = edit.ordinal, definition.ordinal(previous) == ordinal {
                gainStatus = "Already set on AM4"; return
            }
            gainStatus = edit.resetToDefault == true ? "Resetting to the amp’s default…" : "Applying change…"
            if edit.resetToDefault == true {
                let reply = try await query(AM4Message.parameterWrite(edit)!) {
                    $0.parameterValue(definition, action: 8) != nil
                }
                ampResetValue = reply.parameterValue(definition, action: 8)!
            } else {
                try send(AM4Message.parameterWrite(edit)!)
            }
            var verified = false
            for attempt in 0..<3 {
                let actual = try await readParameter(edit.key)
                verified = edit.isConfirmed(by: actual, resetResult: ampResetValue)
                if verified { break }
                if attempt < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            let confirmed = try await readAmpControlsUSB(page: edit.page)
            guard confirmed.context == edit.context, confirmed.model == edit.model, verified,
                  let actual = confirmed.values[edit.key], edit.isConfirmed(by: actual, resetResult: ampResetValue) else {
                throw ConnectionError.message("AM4 returned a different value. Review the current control before retrying.")
            }
            _ = try await readAmpUSB()
            _ = try await readBlocksUSB()
            gainStatus = "Verified on AM4 · not saved"
            append("Amp verified: \(definition.symbol) = \(confirmed.values[edit.key]?.text ?? "read back")")
            #endif
        } catch {
            gainStatus = error.localizedDescription
            append("Amp edit: " + gainStatus)
            throw error
        }
    }

    #if targetEnvironment(simulator)
    private func helperRequest(path: String, body: Data) async throws -> AM4DeviceState {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:32174" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AM4Remote/9", forHTTPHeaderField: "X-AM4-Client")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count < 128_000, (response as? HTTPURLResponse)?.statusCode == 200 else {
            let failure = try? JSONDecoder().decode(AM4ControlError.self, from: data)
            throw ConnectionError.message(failure?.message ?? "The Mac helper could not apply this request.")
        }
        let state = try JSONDecoder().decode(AM4DeviceState.self, from: data)
        guard state.isValid else { throw ConnectionError.message("Restart the simulator helper and rebuild the iPad app.") }
        return state
    }
    #endif

    func savePreset(_ command: AM4PresetSaveCommand) async throws {
        guard command.isValid, canSavePreset, command.location == location else {
            presetSaveStatus = "Wait for the current preset to finish updating before saving."
            throw ConnectionError.message(presetSaveStatus)
        }
        let token = session
        isSavingPreset = true; isApplyingGain = true; presetSaveStatus = "Checking preset…"
        defer { isSavingPreset = false; isApplyingGain = false }
        do {
            #if targetEnvironment(simulator)
            let state = try await helperRequest(path: "/preset/save", body: JSONEncoder().encode(command))
            guard state.presetSaveSupported == true, state.presetEdited == false,
                  let location = state.location, let snapshot = state.snapshot, command.matches(location: location, snapshot: snapshot) else {
                throw ConnectionError.message("The helper did not confirm the preset save.")
            }
            hasUnsavedPresetChanges = false; lastPresetEdit = nil; presetSaveStatus = state.presetSaveStatus ?? "Saved to AM4"
            #else
            await refreshTask?.value
            let result = try await AM4PresetSaveOperation.run(command,
                requireEdited: lastPresetEdit.map { ProcessInfo.processInfo.systemUptime - $0 < 2 } ?? false,
                readLocation: { try await self.query(AM4Message.locationRequest) { $0.location != nil }.location! },
                readSnapshot: { try await self.query(AM4Message.snapshotRequest) { $0.snapshot != nil }.snapshot! },
                commit: {
                    self.presetSaveStatus = "Saving to AM4…"
                    _ = try await self.query(AM4Message.savePresetWrite(command)!, timeoutNanoseconds: 5_000_000_000) { $0.acknowledgesPresetSave }
                },
                readStoredName: { try await self.query(AM4Message.storedPresetNameRequest(command.location)!) { $0.storedPresetName != nil }.storedPresetName! },
                sessionIsCurrent: { self.session == token })
            if result == .alreadyClean {
                hasUnsavedPresetChanges = false; lastPresetEdit = nil; presetSaveStatus = "No unsaved changes on AM4"; return
            }
            let stored = command.snapshot.name
            if let index = presets.firstIndex(where: { $0.id == command.location }) { presets[index] = AM4Preset(id: command.location, name: stored) }
            hasUnsavedPresetChanges = false; lastPresetEdit = nil
            presetSaveStatus = "Saved to AM4 · " + AM4Message.locationLabel(command.location)
            append(presetSaveStatus)
            #endif
        } catch {
            if session == token { presetSaveStatus = "Save could not be verified: " + error.localizedDescription; append(presetSaveStatus) }
            throw error
        }
    }

    func selectPreset(_ target: Int) async throws {
        guard let location else { throw ConnectionError.message("Wait for the AM4 connection.") }
        try await navigate(AM4NavigationCommand(preset: target, expectedLocation: location))
    }

    func selectScene(_ target: Int) async throws {
        guard let location else { throw ConnectionError.message("Wait for the AM4 connection.") }
        try await navigate(AM4NavigationCommand(scene: target, expectedLocation: location))
    }

    func navigate(_ command: AM4NavigationCommand) async throws {
        guard command.isValid, isConnected, !isLoadingPresets, !isApplyingGain, !isNavigating else {
            throw ConnectionError.message("Wait for the current AM4 operation to finish.")
        }
        isNavigating = true
        navigationStatus = command.preset.map { "Loading \(AM4Message.locationLabel($0))…" }
            ?? "Switching to scene \(command.scene! + 1)…"
        defer {
            isNavigating = false
            #if !targetEnvironment(simulator)
            refreshUSB()
            #endif
        }
        do {
            #if targetEnvironment(simulator)
            let state = try await helperRequest(path: "/navigate", body: JSONEncoder().encode(command))
            guard let actualLocation = state.location, let actualSnapshot = state.snapshot,
                  command.isConfirmed(location: actualLocation, scene: actualSnapshot.scene) else {
                throw ConnectionError.message("The helper did not confirm the preset or scene switch.")
            }
            location = actualLocation; snapshot = actualSnapshot
            amp = state.amp; ampControls = state.ampControls
            navigationStatus = state.navigationStatus
            #else
            await refreshTask?.value
            let currentLocation = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
            let currentSnapshot = try await query(AM4Message.snapshotRequest) { $0.snapshot != nil }.snapshot!
            if let target = command.preset, target == currentLocation {
                navigationStatus = "Already on \(AM4Message.locationLabel(target))"; return
            }
            if let target = command.scene {
                let latestLocation = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
                guard currentLocation == command.expectedLocation, latestLocation == command.expectedLocation else {
                    throw ConnectionError.message("The current preset changed. Select a scene from the new preset.")
                }
                if currentSnapshot.scene == target { navigationStatus = "Already on scene \(target + 1)"; return }
            }
            amp = nil; ampControls = nil
            try send(AM4Message.navigationWrite(command)!)
            var previous: AM4Snapshot?
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 100_000_000)
                let first = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
                let observed = try await query(AM4Message.snapshotRequest) { $0.snapshot != nil }.snapshot!
                let last = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
                let reached = first == last && command.isConfirmed(location: first, scene: observed.scene)
                if reached, previous == observed {
                    navigationStatus = command.preset.map { "Preset \(AM4Message.locationLabel($0)) verified on AM4" }
                        ?? "Scene \(observed.scene + 1) verified on AM4"
                    append(navigationStatus)
                    return
                }
                previous = reached ? observed : nil
                if command.scene != nil, first != command.expectedLocation {
                    throw ConnectionError.message("The current preset changed during the scene switch.")
                }
            }
            throw ConnectionError.message("AM4 did not confirm the switch. Check the current preset and scene, then try again.")
            #endif
        } catch {
            navigationStatus = error.localizedDescription
            append("Navigation: " + navigationStatus)
            throw error
        }
    }

    private func readBlockContext() async throws -> AM4BlockContext {
        let first = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
        let snapshot = try await query(AM4Message.snapshotRequest) { $0.snapshot != nil }.snapshot!
        let last = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
        guard first == last else { throw ConnectionError.message("Preset changed while reading block status.") }
        return AM4BlockContext(location: last, scene: snapshot.scene, blocks: snapshot.blockIDs)
    }

    private func readBlocksUSB() async throws -> AM4BlocksState {
        let first = try await readBlockContext()
        var values: [AM4BlockBypass] = []
        for (slot, type) in first.blocks.enumerated() where type != 0 {
            guard let definition = AM4ParameterDefinition.bypass(block: type) else {
                throw ConnectionError.message("This block has no available bypass control.")
            }
            let reply = try await query(AM4Message.parameterRequest(definition)) { $0.blockBypass(type) != nil }
            values.append(AM4BlockBypass(slot: slot, type: type, bypassed: reply.blockBypass(type)!))
        }
        let last = try await readBlockContext()
        guard first == last else { throw ConnectionError.message("Preset or scene changed while reading block status.") }
        let state = AM4BlocksState(context: last, blocks: values)
        guard state.isValid else { throw ConnectionError.message("AM4 returned invalid block status.") }
        if blocks != state {
            if !isApplyingGain { blockStatus = "" }
            append("Blocks at \(AM4Message.locationLabel(last.location)), scene \(last.scene + 1): " +
                   values.map { "slot \($0.slot + 1) \($0.bypassed ? "bypassed" : "active")" }.joined(separator: ", "))
        }
        blocks = state
        return state
    }

    func toggleBlock(slot: Int, type: UInt32) async throws {
        guard let blocks, let block = blocks.block(slot: slot, type: type) else {
            throw ConnectionError.message("Wait for the AM4’s block status.")
        }
        try await changeBlockBypass(AM4BlockBypassCommand(context: blocks.context, slot: slot, type: type,
                                                         expectedBypassed: block.bypassed, bypassed: !block.bypassed))
    }

    func changeBlockBypass(_ command: AM4BlockBypassCommand) async throws {
        guard command.isValid, isConnected, !isLoadingPresets, !isApplyingGain, !isNavigating else {
            throw ConnectionError.message("Wait for the current AM4 operation to finish.")
        }
        isApplyingGain = true
        blockStatus = command.bypassed ? "Bypassing block…" : "Enabling block…"
        defer { isApplyingGain = false }
        do {
            #if targetEnvironment(simulator)
            let state = try await helperRequest(path: "/blocks/bypass", body: JSONEncoder().encode(command))
            guard let confirmed = state.blocks, command.isConfirmed(by: confirmed) else {
                throw ConnectionError.message("The helper did not verify the block’s bypass state.")
            }
            blocks = confirmed
            amp = state.amp; ampControls = state.ampControls
            blockStatus = state.blockStatus
            #else
            await refreshTask?.value
            let current = try await readBlocksUSB()
            guard current.context == command.context, let block = current.block(slot: command.slot, type: command.type) else {
                throw ConnectionError.message("Preset, scene, or block changed. Try again on the current block.")
            }
            if block.bypassed == command.bypassed {
                blockStatus = command.bypassed ? "Block is already bypassed" : "Block is already active"
                return
            }
            guard block.bypassed == command.expectedBypassed else {
                throw ConnectionError.message("This block changed. Review its current state before retrying.")
            }
            try send(AM4Message.blockBypassWrite(command)!)
            for attempt in 0..<3 {
                let actual = try await readBlocksUSB()
                guard actual.context == command.context else {
                    throw ConnectionError.message("Preset or scene changed during the bypass edit.")
                }
                if command.isConfirmed(by: actual) {
                    blockStatus = command.bypassed ? "Bypass verified on AM4 · not saved" : "Active on AM4 · not saved"
                    append("Block \(command.slot + 1) bypass verified: \(command.bypassed)")
                    if let page = ampPage { _ = try await readAmpControlsUSB(page: page) }
                    return
                }
                if attempt < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            throw ConnectionError.message("AM4 returned a different bypass state. Review the block before retrying.")
            #endif
        } catch {
            blockStatus = error.localizedDescription
            append("Bypass edit: " + blockStatus)
            throw error
        }
    }

    private func readUSBPlayback() async throws -> AM4USBPlaybackLevel {
        let reply = try await query(AM4Message.usbPlaybackRequest) { $0.isUSBPlaybackReply }
        guard let value = reply.usbPlaybackLevel else {
            throw ConnectionError.message("USB playback volume is unavailable from the AM4.")
        }
        if usbPlayback != value {
            append("Global USB 1/2 playback: \(value.text)")
            if !isApplyingGain { usbPlaybackStatus = "Read from AM4" }
        }
        usbPlayback = value
        return value
    }

    func changeUSBPlayback(_ command: AM4USBPlaybackCommand) async throws {
        guard command.isValid, isConnected, !isApplyingGain, !isNavigating, !isLoadingPresets else {
            throw ConnectionError.message("Wait for the current AM4 operation to finish.")
        }
        isApplyingGain = true
        usbPlaybackStatus = "Checking USB playback volume…"
        defer { isApplyingGain = false }
        do {
            #if targetEnvironment(simulator)
            let state = try await helperRequest(path: "/usb/playback", body: JSONEncoder().encode(command))
            guard let confirmed = state.usbPlayback, command.isConfirmed(by: confirmed) else {
                throw ConnectionError.message("The helper did not verify the USB playback volume.")
            }
            usbPlayback = confirmed
            usbPlaybackStatus = state.usbPlaybackStatus
            #else
            await refreshTask?.value
            let current = try await readUSBPlayback()
            guard current.matches(command.expected) else {
                throw ConnectionError.message("USB volume changed on the AM4. Review its current level and try again.")
            }
            if command.isConfirmed(by: current) {
                usbPlaybackStatus = "USB volume is already set"; return
            }
            usbPlaybackStatus = "Setting USB playback volume…"
            try send(AM4Message.usbPlaybackWrite(command)!)
            for attempt in 0..<3 {
                let confirmed = try await readUSBPlayback()
                if command.isConfirmed(by: confirmed) {
                    usbPlaybackStatus = "USB volume verified on AM4"
                    append("Global USB playback verified: \(confirmed.text)")
                    return
                }
                if attempt < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            throw ConnectionError.message("AM4 returned a different USB playback volume. Review the current level before retrying.")
            #endif
        } catch {
            usbPlaybackStatus = error.localizedDescription
            append("USB playback: " + usbPlaybackStatus)
            throw error
        }
    }

    private func disconnectUSB() {
        session = UUID()
        refreshTask?.cancel(); refreshTask = nil
        finishQuery(.failure(ConnectionError.message("AM4 disconnected.")))
        amp = nil; ampControls = nil; ampResetValue = nil; blocks = nil; blockStatus = ""; usbPlayback = nil; usbPlaybackStatus = ""; gainStatus = ""; navigationStatus = ""
        timeout?.cancel(); timeout = nil
        nameTimeout?.cancel(); nameTimeout = nil
        if destination != 0, output != 0 { try? send(AM4Message.disconnectRequest) }
        if source != 0, input != 0 { MIDIPortDisconnectSource(input, source) }
        if input != 0 { MIDIPortDispose(input) }
        if output != 0 { MIDIPortDispose(output) }
        // Reconnects and view/background transitions release ports, not the
        // client. Core MIDI cleans up the client when the process terminates.
        source = 0; destination = 0; input = 0; output = 0
        stream = SysExStream()
        catalog = AM4PresetCatalog()
        scanStarted = false
        effectControls = nil; effectResetValue = nil
        snapshot = nil; location = nil; presets = []
        hasUnsavedPresetChanges = false; lastPresetEdit = nil; presetSaveStatus = ""
        isConnected = false; isLoadingPresets = false
    }

    private func receive(_ bytes: [UInt8]) {
        guard source != 0 else { return }
        for message in stream.receive(bytes) {
            if let result = message.location {
                if location != result { hasUnsavedPresetChanges = false; lastPresetEdit = nil; presetSaveStatus = ""; amp = nil; ampControls = nil; effectControls = nil; effectResetValue = nil; blocks = nil; ampResetValue = nil; if !isNavigating { navigationStatus = "" } }
                location = result
            }
            if let result = message.snapshot {
                if snapshot?.scene != result.scene || snapshot?.blockIDs != result.blockIDs { amp = nil; ampControls = nil; effectControls = nil; effectResetValue = nil; blocks = nil; ampResetValue = nil; if !isNavigating { navigationStatus = "" } }
                snapshot = result
                if let edited = result.edited, edited || lastPresetEdit.map({ ProcessInfo.processInfo.systemUptime - $0 >= 2 }) != false {
                    hasUnsavedPresetChanges = edited
                }
            }
            if let pending = pendingQuery, pending.matches(message) { finishQuery(.success(message)) }
            if snapshot != nil, location != nil, !isConnected {
                isConnected = true
                status = "Connected to AM4"
            }
            if isConnected, !scanStarted {
                scanStarted = true
                isLoadingPresets = true
                requestName(catalog.start())
            } else if isLoadingPresets, message.storedPresetName != nil {
                nameTimeout?.cancel()
                let next = catalog.receive(message)
                presets = catalog.presets
                if let next { requestName(next) }
                else {
                    isLoadingPresets = false
                    status = "Connected · \(presets.count) preset slots loaded"
                    refreshUSB()
                    append("Preset catalog complete: \(presets.count) slots. Current: \(location.map(AM4Message.locationLabel) ?? "unknown") / \(snapshot?.name ?? "unknown").")
                }
            }
            append("RX 0x\(String(message.function, radix: 16)) · \(message.payload.count) payload bytes")
        }
    }

    private func requestName(_ bytes: [UInt8]) {
        let token = session
        do { try send(bytes) }
        catch { disconnectUSB(); status = error.localizedDescription; return }
        nameTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.session == token,
                  self.catalog.pendingLocation != nil else { return }
            self.catalog.cancel()
            self.isLoadingPresets = false
            self.status = "Preset list incomplete. Retry on the Mac helper to reload."
        }
    }

    private func send(_ bytes: [UInt8]) throws {
        guard output != 0, destination != 0 else { throw ConnectionError.message("MIDI is disconnected.") }
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw ConnectionError.message("Invalid AM4 MIDI packet size.") }
        let capacity = MemoryLayout<MIDIPacketList>.size + bytes.count + 32
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let pointer = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let packet = MIDIPacketListInit(pointer)
        let result: OSStatus = bytes.withUnsafeBufferPointer { buffer in
            _ = MIDIPacketListAdd(pointer, capacity, packet, 0, buffer.count, buffer.baseAddress!)
            return MIDISend(output, destination, pointer)
        }
        try check(result, operation: "Send AM4 MIDI request")
        if AM4Message(bytes: bytes)?.editsPreset == true {
            hasUnsavedPresetChanges = true; lastPresetEdit = ProcessInfo.processInfo.systemUptime; presetSaveStatus = ""
        }
    }

    private func checkConnection() {
        guard source != 0 else { return }
        let current = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
        if !current.contains(source) {
            disconnectUSB()
            status = "AM4 disconnected. Waiting for USB…"
        }
    }

    #if targetEnvironment(simulator)
    private func readHelper() async {
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:32174/state")!)
            request.timeoutInterval = 2
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count < 128_000 else { throw ConnectionError.message("Unexpected helper response.") }
            let state = try JSONDecoder().decode(AM4DeviceState.self, from: data)
            guard state.isValid else { throw ConnectionError.message("Helper version mismatch. Restart the simulator helper and rebuild the iPad app.") }
            status = state.status
            if !isNavigating { navigationStatus = state.navigationStatus }
            isConnected = state.connected
            if !isApplyingGain {
                amp = state.amp
                ampControls = state.ampControls
                effectControls = state.effectControls
                effectResetValue = state.effectResetValue
                ampResetValue = state.ampResetValue
                blocks = state.blocks
                blockStatus = state.blockStatus
                usbPlayback = state.usbPlayback
                usbPlaybackStatus = state.usbPlaybackStatus
                gainStatus = state.gainStatus
            }
            isLoadingPresets = state.loadingPresets
            snapshot = state.snapshot
            helperSupportsPresetSave = state.presetSaveSupported == true
            if !isSavingPreset { hasUnsavedPresetChanges = state.presetEdited ?? state.snapshot?.edited ?? false; presetSaveStatus = state.presetSaveStatus ?? "" }
            location = state.location
            presets = state.presets
        } catch {
            guard !Task.isCancelled else { return }
            isConnected = false; isLoadingPresets = false
            snapshot = nil; location = nil; presets = []; amp = nil; ampControls = nil; effectControls = nil; effectResetValue = nil; blocks = nil; usbPlayback = nil
            status = "Waiting for simulator helper. Run Tools/run-simulator-helper.sh on your Mac."
        }
    }
    #endif

    private func append(_ entry: String) {
        log.append(entry)
        if log.count > 60 { log.removeFirst(log.count - 60) }
        if ProcessInfo.processInfo.arguments.contains("--connection-diagnostics") {
            print("[AM4] \(entry)")
        }
    }

    private static func name(_ object: MIDIObjectRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value) == noErr else { return "Unknown" }
        return value?.takeRetainedValue() as String? ?? "Unknown"
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            let recovery = status == -2 ? " Fully close and reopen AM4 Remote." : ""
            throw ConnectionError.message("\(operation) failed (Core MIDI \(status)).\(recovery)")
        }
    }

    private enum ConnectionError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }
}


extension AM4Connection {
    func showEffectPage(_ selection: AM4EffectPageSelection) async throws {
        guard selection.isValid else { return }
        if selection.page != nil && (isApplyingGain || isNavigating) { return }
        if selection.page == nil {
            if effectPage?.block == selection.block && effectPage?.slot == selection.slot { effectPage = nil; effectControls = nil }
        } else {
            ampPage = nil; ampControls = nil; effectControls = nil; effectPage = selection
        }
        #if targetEnvironment(simulator)
        _ = try await helperRequest(path: "/effect/page", body: JSONEncoder().encode(selection))
        await readHelper()
        #else
        await refreshTask?.value
        if selection.page != nil { refreshUSB(); await refreshTask?.value }
        #endif
    }

    private func readEffectChannelUSB(_ block: Int) async throws -> Int {
        for _ in 0..<4 {
            let message = try await query(AM4Message.effectChannelRequest(block)) { $0.isEffectChannelReply(block) }
            if let channel = message.effectChannel(block) { return channel }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw ConnectionError.message("The block channel is changing. Try again once it settles.")
    }

    private func readEffectContextUSB(slot: Int, block: Int) async throws -> AM4EffectContext {
        let location = try await query(AM4Message.locationRequest) { $0.location != nil }.location!
        let snapshot = try await query(AM4Message.snapshotRequest) { $0.snapshot != nil }.snapshot!
        guard (0..<4).contains(slot), snapshot.blockIDs[slot] == UInt32(block), snapshot.blockIDs.filter({ $0 == UInt32(block) }).count == 1 else {
            throw ConnectionError.message("The selected block changed. Reopen its editor.")
        }
        let channel = try await readEffectChannelUSB(block)
        let context = AM4EffectContext(location: location, scene: snapshot.scene, blocks: snapshot.blockIDs, slot: slot, block: block, channel: channel)
        guard context.isValid else { throw ConnectionError.message("The selected block is unavailable.") }
        return context
    }

    private func readEffectValueUSB(_ key: String, block: Int) async throws -> AM4ParameterValue {
        guard let definition = AM4EffectsCatalog.shared.effect(block)?.definition(key, addressedTo: block) else { throw ConnectionError.message("Unknown effect control.") }
        let trace = ProcessInfo.processInfo.arguments.contains("--am4-trace")
        if trace { print("AM4 read effect \(key) \(definition.symbol)") }
        do {
            let message = try await query(AM4Message.parameterRequest(definition)) { message in
                let matches = message.isParameterResponse(definition)
                if trace, message.function == 1, !matches || message.parameterValue(definition) == nil { print("AM4 unmatched/invalid parameter payload: \(message.payload)") }
                return matches
            }
            guard let result = message.parameterValue(definition), definition.accepts(result) else { throw ConnectionError.message("The AM4 returned an invalid effect value.") }
            if trace { print("AM4 read result \(key): \(result.raw) / \(result.normalized) / \(result.text)") }
            return result
        } catch { throw ConnectionError.message("\(definition.symbol) (\(key)): " + error.localizedDescription) }
    }

    private func readEffectControlsUSB(_ selection: AM4EffectPageSelection) async throws -> AM4EffectControls {
        guard let effect = AM4EffectsCatalog.shared.effect(selection.block), let page = selection.page, let layout = effect.page(page) else {
            throw ConnectionError.message("Unknown effect page.")
        }
        let context = try await readEffectContextUSB(slot: selection.slot, block: selection.block)
        var values = [effect.typeKey: try await readEffectValueUSB(effect.typeKey, block: selection.block)]
        guard effect.models.indices.contains(Int(values[effect.typeKey]!.raw)) else { throw ConnectionError.message("This model needs updated editor definitions.") }
        let candidates = layout.controls.filter { $0.conditions.filter { $0.key == effect.typeKey }.allSatisfy { $0.matches(values) } }
        let gates = Set(candidates.flatMap { $0.conditions.map(\.key) + ($0.lockKey.map { [$0] } ?? []) }).subtracting([effect.typeKey])
        for key in gates.sorted() { values[key] = try await readEffectValueUSB(key, block: selection.block) }
        for key in Set(effect.controls(page: page, values: values).map(\.key)).sorted() where values[key] == nil {
            values[key] = try await readEffectValueUSB(key, block: selection.block)
        }
        for key in gates.sorted() {
            guard try await readEffectValueUSB(key, block: selection.block).matches(values[key]!) else { throw ConnectionError.message("Effect options changed while reading. Refreshing…") }
        }
        let model = try await readEffectValueUSB(effect.typeKey, block: selection.block)
        let last = try await readEffectContextUSB(slot: selection.slot, block: selection.block)
        guard last == context, model.matches(values[effect.typeKey]!) else { throw ConnectionError.message("Effect model or channel changed while reading. Refreshing…") }
        let state = AM4EffectControls(context: context, model: Int(model.raw), modelName: model.text, page: page, values: values)
        guard state.isValid else { throw ConnectionError.message("The AM4 returned invalid effect controls.") }
        if effectPage?.slot == selection.slot && effectPage?.block == selection.block && effectPage?.page == page {
            if effectControls != state { effectControls = state }
            if !isApplyingGain { gainStatus = "Read from AM4" }
        }
        return state
    }

    func changeEffectParameter(_ edit: AM4EffectEdit) async throws {
        guard edit.isValid, isConnected, !isApplyingGain, !isNavigating, !isLoadingPresets else { throw ConnectionError.message("Wait for the block controls to finish loading.") }
        isApplyingGain = true; effectResetValue = nil; gainStatus = "Checking current block…"
        defer { isApplyingGain = false }
        do {
            #if targetEnvironment(simulator)
            let state = try await helperRequest(path: "/effect/parameter", body: JSONEncoder().encode(edit))
            guard let confirmed = state.effectControls, confirmed.context == edit.state.context, confirmed.model == edit.state.model,
                  let actual = confirmed.values[edit.key], edit.confirmed(actual, reset: state.effectResetValue) else { throw ConnectionError.message("The helper did not verify the edit.") }
            effectControls = confirmed; effectResetValue = state.effectResetValue; gainStatus = state.gainStatus
            #else
            await refreshTask?.value
            let selection = AM4EffectPageSelection(slot: edit.state.context.slot, block: edit.state.context.block, page: edit.state.page)
            guard effectPage?.page == selection.page, effectPage?.block == selection.block, effectPage?.slot == selection.slot else { throw ConnectionError.message("The editor page changed. Try again.") }
            let current = try await readEffectControlsUSB(selection)
            guard current.context == edit.state.context, current.model == edit.state.model,
                  let previous = current.values[edit.key], previous.matches(edit.expected) else { throw ConnectionError.message("The effect or control changed. Review it before retrying.") }
            let refreshed = AM4EffectEdit(state: current, key: edit.key, expected: previous, normalized: edit.normalized, ordinal: edit.ordinal, direction: edit.direction, resetToDefault: edit.resetToDefault)
            guard refreshed.isValid, let frame = refreshed.frame, let definition = AM4EffectsCatalog.shared.effect(selection.block)?.definition(edit.key, addressedTo: selection.block) else { throw ConnectionError.message("This control is not currently editable.") }
            gainStatus = "Applying change…"
            if edit.resetToDefault == true {
                let reply = try await query(frame) { $0.parameterValue(definition, action: 8) != nil }
                effectResetValue = reply.parameterValue(definition, action: 8)
            } else { try send(frame) }
            var verified = false
            for _ in 0..<4 {
                let actual = try await readEffectValueUSB(edit.key, block: selection.block)
                if edit.confirmed(actual, reset: effectResetValue) { verified = true; break }
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            let confirmed = try await readEffectControlsUSB(selection)
            guard verified, confirmed.context == current.context, confirmed.model == current.model,
                  let actual = confirmed.values[edit.key], edit.confirmed(actual, reset: effectResetValue) else { throw ConnectionError.message("The AM4 returned a different value. Review the current control.") }
            _ = try await readBlocksUSB()
            gainStatus = "Verified on AM4 · not saved"
            append("Effect edit verified: \(definition.symbol) = \(actual.text)")
            #endif
        } catch { gainStatus = error.localizedDescription; append("Effect edit: " + gainStatus); throw error }
    }

    func selectEffect(_ command: AM4EffectSelection) async throws {
        guard command.isValid, isConnected, !isApplyingGain, !isNavigating, !isLoadingPresets else { throw ConnectionError.message("Wait for the block controls to finish loading.") }
        isApplyingGain = true; effectResetValue = nil; gainStatus = "Loading selection…"
        defer { isApplyingGain = false }
        do {
            #if targetEnvironment(simulator)
            let state = try await helperRequest(path: "/effect/select", body: JSONEncoder().encode(command))
            guard let confirmed = state.effectControls, confirmed.context.slot == command.state.context.slot,
                  confirmed.context.block == command.state.context.block, confirmed.context.location == command.state.context.location,
                  confirmed.context.scene == command.state.context.scene, confirmed.context.blocks == command.state.context.blocks,
                  confirmed.context.channel == (command.channel ?? command.state.context.channel), command.model == nil || confirmed.model == command.model else { throw ConnectionError.message("The helper did not confirm the selection.") }
            effectControls = confirmed; blocks = state.blocks; gainStatus = state.gainStatus
            #else
            await refreshTask?.value
            let origin = command.state
            let selection = AM4EffectPageSelection(slot: origin.context.slot, block: origin.context.block, page: origin.page)
            guard effectPage?.slot == selection.slot, effectPage?.block == selection.block else { throw ConnectionError.message("The selected block changed.") }
            let current = try await readEffectControlsUSB(selection)
            guard current.context == origin.context, current.model == origin.model else { throw ConnectionError.message("The effect changed. Review its current type and channel.") }
            if let channel = command.channel {
                try send(AM4Message.effectValueWrite(block: current.context.block, parameter: 2002, value: Float(channel)))
                var matched = false
                for _ in 0..<5 {
                    if try await readEffectChannelUSB(current.context.block) == channel { matched = true; break }
                    try await Task.sleep(nanoseconds: 60_000_000)
                }
                guard matched else { throw ConnectionError.message("The AM4 did not confirm the channel switch.") }
            } else if let model = command.model {
                let typeParameter = AM4EffectsCatalog.shared.effect(current.context.block)!.typeParameter
                try send(AM4Message.effectValueWrite(block: current.context.block, parameter: typeParameter, value: Float(model)))
                var matched = false
                let key = AM4EffectsCatalog.shared.effect(current.context.block)!.typeKey
                for _ in 0..<5 {
                    if try await readEffectValueUSB(key, block: current.context.block).raw == UInt32(model) { matched = true; break }
                    try await Task.sleep(nanoseconds: 60_000_000)
                }
                guard matched else { throw ConnectionError.message("The AM4 did not confirm the type selection.") }
            } else if let id = command.libraryID, let entry = AM4EffectsLibrary.shared.entries.first(where: { $0.id == id }), let file = entry.parsed {
                let original = try await readEffectBankUSB(current.context.block)
                guard let merged = original.mergingEffectLibrary(file, channel: current.context.channel), try await readEffectContextUSB(slot: selection.slot, block: selection.block) == current.context else { throw ConnectionError.message("This library format does not match the current block or firmware.") }
                try send(AM4Message.libraryTransferMode(block: selection.block)!)
                try await Task.sleep(nanoseconds: 5_000_000)
                for frame in merged.frames {
                    let function = frame[5]
                    let ack = try await query(frame) { $0.function == 0x64 && $0.payload.first == function }
                    guard ack.payload == [function, 0] else { throw ConnectionError.message("The AM4 rejected the library transfer.") }
                }
                var matched = false
                for delay in [UInt64(200_000_000), 300_000_000, 600_000_000, 1_000_000_000] {
                    try await Task.sleep(nanoseconds: delay)
                    let actual = try await readEffectBankUSB(selection.block)
                    if merged.matchesEffect(actual, channel: current.context.channel, allChannels: file.allChannels) { matched = true; break }
                }
                guard matched else { throw ConnectionError.message("Library settings did not finish matching on the AM4. Refresh before retrying.") }
            }
            effectControls = nil
            let confirmed = try await readEffectControlsUSB(selection)
            guard confirmed.context.location == origin.context.location, confirmed.context.scene == origin.context.scene,
                  confirmed.context.blocks == origin.context.blocks, confirmed.context.channel == (command.channel ?? origin.context.channel),
                  command.model == nil || confirmed.model == command.model else { throw ConnectionError.message("The block changed during loading. Refresh its editor.") }
            _ = try await readBlocksUSB()
            gainStatus = "Verified on AM4 · not saved"
            append("Effect selection verified: \(confirmed.modelName), block=\(selection.block), channel=\(confirmed.context.channel)")
            #endif
        } catch { effectControls = nil; gainStatus = error.localizedDescription; append("Effect selection: " + gainStatus); throw error }
    }
}

#if AM4_SIMULATOR_HELPER
/// Loopback-only helper with validated, read-back-verified Amp operations.
@MainActor
private final class AM4LocalHelper {
    var onStatus: ((String) -> Void)?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let state: () -> AM4DeviceState?
    private let setGain: (AM4GainCommand) async throws -> AM4DeviceState
    private let selectPage: (String?) async throws -> AM4DeviceState
    private let editAmp: (AM4AmpEdit) async throws -> AM4DeviceState
    private let selectAmp: (AM4AmpSelection) async throws -> AM4DeviceState
    private let selectEffectPage: (AM4EffectPageSelection) async throws -> AM4DeviceState
    private let editEffect: (AM4EffectEdit) async throws -> AM4DeviceState
    private let selectEffect: (AM4EffectSelection) async throws -> AM4DeviceState
    private let navigate: (AM4NavigationCommand) async throws -> AM4DeviceState
    private let bypassBlock: (AM4BlockBypassCommand) async throws -> AM4DeviceState
    private let setUSBPlayback: (AM4USBPlaybackCommand) async throws -> AM4DeviceState
    private let savePreset: (AM4PresetSaveCommand) async throws -> AM4DeviceState

    init(state: @escaping () -> AM4DeviceState?,
         setGain: @escaping (AM4GainCommand) async throws -> AM4DeviceState,
         selectPage: @escaping (String?) async throws -> AM4DeviceState,
         editAmp: @escaping (AM4AmpEdit) async throws -> AM4DeviceState,
         selectAmp: @escaping (AM4AmpSelection) async throws -> AM4DeviceState,
         selectEffectPage: @escaping (AM4EffectPageSelection) async throws -> AM4DeviceState,
         editEffect: @escaping (AM4EffectEdit) async throws -> AM4DeviceState,
         selectEffect: @escaping (AM4EffectSelection) async throws -> AM4DeviceState,
         navigate: @escaping (AM4NavigationCommand) async throws -> AM4DeviceState,
         bypassBlock: @escaping (AM4BlockBypassCommand) async throws -> AM4DeviceState,
         setUSBPlayback: @escaping (AM4USBPlaybackCommand) async throws -> AM4DeviceState,
         savePreset: @escaping (AM4PresetSaveCommand) async throws -> AM4DeviceState) {
        self.state = state
        self.setGain = setGain
        self.selectPage = selectPage
        self.editAmp = editAmp
        self.selectAmp = selectAmp
        self.selectEffectPage = selectEffectPage
        self.editEffect = editEffect
        self.selectEffect = selectEffect
        self.navigate = navigate
        self.bypassBlock = bypassBlock
        self.setUSBPlayback = setUSBPlayback; self.savePreset = savePreset
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 32174)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] event in
                Task { @MainActor in
                    switch event {
                    case .ready: self?.onStatus?("Helper ready · localhost:32174")
                    case .failed(let error): self?.onStatus?("Helper unavailable: \(error.localizedDescription). Close any older Mac helper.")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch { onStatus?("Helper could not start: \(error.localizedDescription)") }
    }

    func stop() {
        listener?.cancel(); listener = nil
        let active = Array(connections.values)
        connections.removeAll()
        for connection in active { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, buffer: Data())
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.finish(id)
        }
    }

    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 36_864, error == nil else { self.finish(id); return }
                guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { self.finish(id) }
                    else { self.read(connection, id: id, buffer: buffer) }
                    return
                }
                let lines = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
                    .components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else {
                        self.respond(id, status: "400 Bad Request", body: Data()); return
                    }
                    let name = line[..<colon].lowercased()
                    guard headers[name] == nil else {
                        self.respond(id, status: "400 Bad Request", body: Data()); return
                    }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil,
                      let length = Int(headers["content-length"] ?? "0"), (0...32_768).contains(length) else {
                    self.respond(id, status: "400 Bad Request", body: Data()); return
                }
                let end = separator.upperBound + length
                guard buffer.count >= end else {
                    if complete { self.finish(id) }
                    else { self.read(connection, id: id, buffer: buffer) }
                    return
                }
                guard buffer.count == end else {
                    self.respond(id, status: "400 Bad Request", body: Data()); return
                }
                let line = lines.first ?? ""
                if line == "GET /state HTTP/1.1" || line == "GET /state HTTP/1.0" {
                    guard length == 0, let state = self.state(), let body = try? JSONEncoder().encode(state) else {
                        self.respond(id, status: "503 Service Unavailable", body: Data()); return
                    }
                    self.respond(id, status: "200 OK", body: body)
                } else if line == "POST /amp/gain HTTP/1.1" {
                    guard headers["x-am4-client"] == "AM4Remote/2", headers["origin"] == nil,
                          headers["content-type"] == "application/json",
                          let command = try? JSONDecoder().decode(AM4GainCommand.self, from:
                            buffer.subdata(in: separator.upperBound..<end)), command.isValid else {
                        self.respond(id, status: "400 Bad Request", body: Data()); return
                    }
                    do {
                        let state = try await self.setGain(command)
                        self.respond(id, status: "200 OK", body: try JSONEncoder().encode(state))
                    } catch {
                        let body = (try? JSONEncoder().encode(AM4ControlError(message: error.localizedDescription))) ?? Data()
                        self.respond(id, status: "409 Conflict", body: body)
                    }
                } else if line == "POST /amp/page HTTP/1.1" || line == "POST /amp/parameter HTTP/1.1" || line == "POST /amp/select HTTP/1.1" || line == "POST /effect/page HTTP/1.1" || line == "POST /effect/parameter HTTP/1.1" || line == "POST /effect/select HTTP/1.1" || line == "POST /navigate HTTP/1.1" || line == "POST /blocks/bypass HTTP/1.1" || line == "POST /usb/playback HTTP/1.1" || line == "POST /preset/save HTTP/1.1" {
                    guard headers["x-am4-client"] == "AM4Remote/9", headers["origin"] == nil,
                          headers["content-type"] == "application/json" else {
                        self.respond(id, status: "400 Bad Request", body: Data()); return
                    }
                    let body = buffer.subdata(in: separator.upperBound..<end)
                    do {
                        let result: AM4DeviceState
                        if line == "POST /preset/save HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4PresetSaveCommand.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.savePreset(command)
                        } else if line == "POST /effect/page HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4EffectPageSelection.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.selectEffectPage(command)
                        } else if line == "POST /effect/parameter HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4EffectEdit.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.editEffect(command)
                        } else if line == "POST /effect/select HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4EffectSelection.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.selectEffect(command)
                        } else if line == "POST /amp/page HTTP/1.1" {
                            guard let selection = try? JSONDecoder().decode(AM4PageSelection.self, from: body),
                                  selection.page == nil || AM4AmpCatalog.shared.page(selection.page!) != nil else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.selectPage(selection.page)
                        } else if line == "POST /amp/select HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4AmpSelection.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.selectAmp(command)
                        } else if line == "POST /usb/playback HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4USBPlaybackCommand.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.setUSBPlayback(command)
                        } else if line == "POST /blocks/bypass HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4BlockBypassCommand.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.bypassBlock(command)
                        } else if line == "POST /navigate HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4NavigationCommand.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.navigate(command)
                        } else {
                            guard let edit = try? JSONDecoder().decode(AM4AmpEdit.self, from: body), edit.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.editAmp(edit)
                        }
                        self.respond(id, status: "200 OK", body: try JSONEncoder().encode(result))
                    } catch {
                        let body = (try? JSONEncoder().encode(AM4ControlError(message: error.localizedDescription))) ?? Data()
                        self.respond(id, status: "409 Conflict", body: body)
                    }
                } else { self.respond(id, status: "404 Not Found", body: Data()) }
            }
        }
    }

    private func respond(_ id: UUID, status: String, body: Data) {
        guard let connection = connections[id] else { return }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(id) }
        })
    }

    private func finish(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}
#endif

private struct AM4PageSelection: Codable { let page: String? }
