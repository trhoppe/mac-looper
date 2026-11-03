import SwiftUI

struct AM4RemoteView: View {
    @ObservedObject var midi: AM4Connection
    @State private var navigationError: String?
    @Environment(\.displayScale) private var displayScale
    @State private var selection: Int?
    @State private var selectedBlock: BlockSelection?
    private let accent = AM4Appearance.accent

    private var selectedPreset: AM4Preset? {
        let index = selection ?? midi.location
        return midi.presets.first { $0.id == index }
    }

    private var detailTitle: String {
        guard let preset = selectedPreset else { return "AM4 presets" }
        if preset.id == midi.location, let name = midi.snapshot?.name, !name.isEmpty { return name }
        return preset.isEmpty ? "Empty preset slot" : preset.name
    }

    var body: some View {
        AM4WorkspaceSplit {
            VStack(spacing: 0) {
                connectionStatus.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("Presets").font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(midi.presets.count) / 104").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
                if midi.presets.isEmpty {
                    VStack(spacing: 12) {
                        if midi.isConnected || midi.status.hasPrefix("Connecting") {
                            ProgressView()
                        }
                        Text(midi.isConnected ? "Reading presets…" : "Waiting for AM4")
                            .font(.headline)
                        Text("Your AM4’s presets will appear here after connection.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List(selection: $selection) {
                            ForEach(midi.presets) { preset in
                                HStack(spacing: 12) {
                                    Text(AM4Message.locationLabel(preset.id))
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(selection == preset.id ? Color.primary : accent)
                                        .frame(width: 30, alignment: .leading)
                                    Text(preset.isEmpty ? "Empty" : preset.name)
                                        .foregroundStyle(preset.isEmpty ? .secondary : .primary)
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                    if preset.id == midi.location {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.caption)
                                            .foregroundStyle(selection == preset.id ? Color.primary : accent)
                                            .accessibilityLabel("Current preset on AM4")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 34)
                                    .am4PresetRowHighlight(selected: selection == preset.id)
                                    #if os(macOS)
                                    .padding(.horizontal, -9)
                                    #endif
                                    .id(preset.id).tag(preset.id)
                                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden).tint(.gray).accentColor(.gray)
                            .contentMargins(.horizontal, 0, for: .scrollContent)
                            .disabled(!midi.isConnected || midi.isLoadingPresets || midi.isApplyingGain || midi.isNavigating)
                            .onAppear {
                                if let current = midi.location { proxy.scrollTo(current, anchor: .center) }
                            }
                            .onChange(of: midi.presets.count) { _, count in
                                if count == 104, let current = midi.location { proxy.scrollTo(current, anchor: .center) }
                            }
                            .onChange(of: midi.location) { _, current in
                                guard let current else { return }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(current, anchor: .center)
                                }
                            }
                        }
                }
            }.background(AM4Appearance.background)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    detail
                    if !midi.log.isEmpty {
                        DisclosureGroup("Connection details") {
                            Text(midi.log.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(28).frame(maxWidth: 1000, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AM4Appearance.panel)
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .onAppear { if selection == nil { selection = midi.location } }
        .onChange(of: selection) { _, target in
            guard let target, target != midi.location, midi.isConnected else { return }
            navigationError = nil
            Task {
                do { try await midi.selectPreset(target) }
                catch {
                    navigationError = error.localizedDescription
                    selection = midi.location
                }
            }
        }
        .allowsHitTesting(selectedBlock == nil)
        .accessibilityHidden(selectedBlock != nil)
        .overlay {
            if let block = selectedBlock {
                GeometryReader { geometry in
                    ZStack {
                        Color.black.opacity(0.65).ignoresSafeArea()
                        Group {
                        if AM4EffectsCatalog.shared.effect(Int(block.type)) != nil {
                            EffectPanel(midi: midi, slot: block.id, blockID: Int(block.type), close: { selectedBlock = nil })
                        } else {
                            BlockPanel(midi: midi, blockID: block.type, close: { selectedBlock = nil })
                        }
                        }
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12), lineWidth: 1) }
                            .shadow(color: .black.opacity(0.6), radius: 24)
                            .padding(.horizontal, max(12, geometry.size.width * 0.015))
                            .padding(.vertical, max(12, geometry.size.height * 0.02))
                    }
                }.accessibilityElement(children: .contain)
            }
        }
        .onChange(of: midi.snapshot?.blockIDs) { _, blocks in
            if let block = selectedBlock, blocks?[block.id] != block.type { selectedBlock = nil }
        }
        .onChange(of: midi.location) { previous, location in
            selectedBlock = nil
            if selection == nil || selection == previous { selection = location }
        }
        .onChange(of: midi.isConnected) { _, connected in
            if !connected { selection = nil }
            else { selection = midi.location }
        }
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(midi.isConnected ? "AM4 connected" : "Connecting", systemImage:
                    midi.isConnected ? "checkmark.circle.fill" : "cable.connector")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(midi.isConnected ? accent : .secondary)
            Text(midi.status).font(.caption).foregroundStyle(.secondary)
            if midi.isNavigating { ProgressView().controlSize(.small) }
            if let navigationError {
                Text(navigationError).font(.caption).foregroundStyle(.red)
            } else if !midi.navigationStatus.isEmpty {
                Text(midi.navigationStatus).font(.caption).foregroundStyle(.secondary)
            }
            if !midi.blockStatus.isEmpty {
                Text(midi.blockStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text(AM4Connection.transportLabel).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var detail: some View {
        if !midi.isConnected {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "cable.connector").font(.system(size: 36)).foregroundStyle(accent)
                Text("Connecting to your AM4").font(.largeTitle.weight(.semibold))
                Text(midi.status).foregroundStyle(.secondary)
                #if targetEnvironment(simulator)
                Text("Run Tools/run-simulator-helper.sh on your Mac with the AM4 plugged into USB. The simulator connects to that helper automatically.")
                    .foregroundStyle(.secondary)
                #else
                Text("Connect a powered AM4 over USB. This app will retry automatically.")
                    .foregroundStyle(.secondary)
                #endif
            }.padding(.vertical, 30)
        } else if let preset = selectedPreset {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(AM4Message.locationLabel(preset.id))
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(accent).fixedSize()
                    Text(detailTitle)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        guard let snapshot = midi.snapshot else { return }
                        Task { try? await midi.savePreset(AM4PresetSaveCommand(location: preset.id, snapshot: snapshot)) }
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(midi.hasUnsavedPresetChanges ? Color.orange : Color.secondary).frame(width: 6, height: 6)
                            Text(midi.isSavingPreset ? "Saving…" : "Save")
                        }
                    }.buttonStyle(AM4NativeButtonStyle()).controlSize(.large)
                        .disabled(!midi.canSavePreset || preset.id != midi.location)
                        .accessibilityLabel("Save preset to AM4")
                        .accessibilityValue(midi.hasUnsavedPresetChanges ? "Unsaved changes" : "No unsaved changes")
                }
                if !midi.presetSaveStatus.isEmpty {
                    Text(midi.presetSaveStatus).font(.caption).foregroundStyle(.secondary)
                }
                if preset.id == midi.location, let snapshot = midi.snapshot {
                    if snapshot.name != preset.name {
                        Text("Stored as “\(preset.name)”")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Blocks").font(.headline).padding(.top, 8)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                        ForEach(Array(snapshot.blockIDs.enumerated()), id: \.offset) { index, type in
                            let state = midi.blocks?.block(slot: index, type: type)
                            let active = state?.bypassed == false
                            Button {
                                selectedBlock = BlockSelection(id: index, type: type)
                            } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("SLOT \(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                                    Label(BlockLabel.name(type), systemImage: type == 0x3A ? "hifispeaker" : "waveform")
                                        .font(.headline).foregroundStyle(active ? accent : Color(white: 0.82))
                                    Text(type == 0 ? "Empty" : (state == nil ? "Reading status…" : ((type == 0x3A || AM4EffectsCatalog.shared.effect(Int(type)) != nil) ? "Edit controls" : "View block")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(12)
                                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(active ? accent : .clear, lineWidth: 1 / displayScale)
                                    }.contentShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(AM4ButtonStyle())
                                .highPriorityGesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { tap in
                                    switch tap {
                                    case .first:
                                        guard state != nil else { return }
                                        navigationError = nil
                                        Task {
                                            do { try await midi.toggleBlock(slot: index, type: type) }
                                            catch { navigationError = error.localizedDescription }
                                        }
                                    case .second:
                                        selectedBlock = BlockSelection(id: index, type: type)
                                    }
                                })
                                .disabled(type == 0 || midi.isApplyingGain || midi.isNavigating)
                                .accessibilityValue(state == nil ? "Reading status" : (active ? "Active" : "Bypassed"))
                                .accessibilityAction(named: Text(active ? "Bypass block" : "Enable block")) {
                                    guard state != nil else { return }
                                    Task {
                                        do { try await midi.toggleBlock(slot: index, type: type) }
                                        catch { navigationError = error.localizedDescription }
                                    }
                                }
                        }
                    }
                    Text("Scenes").font(.headline).padding(.top, 8)
                    ForEach(0..<4) { index in
                        Button {
                            navigationError = nil
                            Task {
                                do { try await midi.selectScene(index) }
                                catch { navigationError = error.localizedDescription }
                            }
                        } label: {
                        HStack(spacing: 14) {
                            Text("\(index + 1)")
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(accent)
                            Text(snapshot.sceneNames[index].isEmpty ? "Unnamed scene" : snapshot.sceneNames[index])
                            Spacer()
                            if index == snapshot.scene {
                                Text("Current").font(.caption2.weight(.bold)).foregroundStyle(accent)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.white.opacity(index == snapshot.scene ? 0.112 : 0.04), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(AM4ButtonStyle(isSelected: index == snapshot.scene))
                            .disabled(midi.isNavigating || midi.isApplyingGain || midi.isLoadingPresets)
                            .accessibilityLabel("Scene \(index + 1), \(snapshot.sceneNames[index])")
                    }
                } else {
                    Text("Loading this preset on your AM4…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Reading your AM4’s preset list…").font(.title2)
        }
    }
}


private struct BlockSelection: Identifiable {
    let id: Int
    let type: UInt32
}

private enum BlockLabel {
    static func name(_ type: UInt32) -> String {
        [0: "Empty", 0x2E: "Compressor", 0x32: "Graphic EQ", 0x36: "Parametric EQ",
         0x3A: "Amp", 0x42: "Reverb", 0x46: "Delay", 0x4E: "Chorus", 0x52: "Flanger",
         0x56: "Rotary", 0x5A: "Phaser", 0x5E: "Wah", 0x66: "Volume/Pan",
         0x6A: "Tremolo", 0x72: "Filter", 0x76: "Drive", 0x77: "Drive 2", 0x7A: "Enhancer", 0x92: "Gate"][type]
            ?? "Block 0x" + String(type, radix: 16).uppercased()
    }
}

private struct BlockPanel: View {
    @ObservedObject var midi: AM4Connection
    let blockID: UInt32
    let close: () -> Void
    @State private var page = "Amp"
    @State private var selectionFailure: String?
    private let catalog = AM4AmpCatalog.shared
    private let dialAccent = AM4Appearance.accent

    private var pages: [AM4AmpPage] {
        ["Amp", "GEQ", "Cabinet", "Extras", "Expert", "Preamp", "Power Amp", "Speaker"]
            .compactMap(catalog.page)
    }

    var body: some View {
        VStack(spacing: 0) {
            AM4EditorHeader(title: BlockLabel.name(blockID),
                subtitle: midi.ampControls.map { "\(AM4Message.locationLabel($0.context.location)) · Scene \($0.context.scene + 1)" },
                busy: midi.isApplyingGain, close: close) {
                    if blockID == 0x3A { ampSelectionMenus }
                }
            Divider()
            if blockID == 0x3A {
                HStack(spacing: 10) {
                    Text("Channel").font(.subheadline).foregroundStyle(.secondary)
                    if let current = midi.ampControls, let channel = current.context.channel {
                        ForEach(0..<4) { index in
                            Button {
                                select(AM4AmpSelection(context: current.context, expectedModel: current.model, channel: index))
                            } label: {
                                Text(String(UnicodeScalar(65 + index)!)).font(.headline)
                                    .foregroundStyle(channel == index ? dialAccent : .secondary)
                                    .frame(width: 48, height: 36)
                                    .background(channel == index ? dialAccent.opacity(0.16) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(channel == index ? dialAccent.opacity(0.65) : .clear))
                            }.buttonStyle(AM4ButtonStyle()).accessibilityLabel("Amp channel " + String(UnicodeScalar(65 + index)!))
                                .accessibilityAddTraits(channel == index ? [.isSelected] : [])
                        }
                    } else { ProgressView().controlSize(.small) }
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 10)
                    .disabled(midi.isApplyingGain || midi.isNavigating || !midi.isConnected)
                Divider()
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(pages) { item in
                                Button { page = item.id } label: {
                                    Text(item.title == "Cabinet" ? "Cab" : item.title)
                                        .font(.headline).foregroundStyle(page == item.id ? .white : .secondary)
                                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                        .padding(.horizontal, 18)
                                        .background(page == item.id ? Color.white.opacity(0.08) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(alignment: .leading) {
                                            if page == item.id { Capsule().fill(dialAccent).frame(width: 3).padding(.vertical, 12) }
                                        }
                                }.buttonStyle(AM4ButtonStyle())
                            }
                        }.padding(.vertical, 14).padding(.horizontal, 8)
                    }.frame(width: 148).background(.white.opacity(0.025))
                        .disabled(midi.isApplyingGain)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if let amp = midi.ampControls, amp.page == page {
                                let controls = catalog.controls(page: page, values: amp.values)
                                let bands = controls.filter { catalog.definition($0.key)?.isGraphicEQBand == true }
                                if !bands.isEmpty { EQBandStrip(midi: midi, controls: bands, state: .amp(amp)) }
                                let groups = sections(controls.filter { catalog.definition($0.key)?.isGraphicEQBand != true })
                                ForEach(groups) { group in
                                    VStack(alignment: .leading, spacing: 18) {
                                        if group.id.caseInsensitiveCompare(page) != .orderedSame {
                                            Text(group.id.replacingOccurrences(of: "_", with: " "))
                                                .font(.caption.weight(.semibold)).tracking(1)
                                                .foregroundStyle(.secondary)
                                        }
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 18)], alignment: .leading, spacing: 28) {
                                            ForEach(group.controls) { control in
                                                if let definition = catalog.definition(control.key), let actual = amp.values[control.key] {
                                                    AmpParameterRow(midi: midi, control: control, definition: definition,
                                                                    actual: actual, state: amp)
                                                        .id("\(amp.context.location):\(amp.context.scene):\(amp.model):\(control.id)")
                                                }
                                            }
                                        }
                                    }
                                }
                            } else {
                                ProgressView("Reading \(page) controls…")
                                    .frame(maxWidth: .infinity, minHeight: 180)
                            }
                        }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Text(midi.gainStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Drag to adjust · Tap a number to type · Double-tap to reset")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button {
                        Task { await midi.showAmpPage(page) }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(AM4NativeButtonStyle()).accessibilityLabel("Refresh Amp controls").disabled(midi.isApplyingGain)
                }.padding(.horizontal, 20).padding(.vertical, 8)
            } else {
                Text("Loaded in the current preset. Controls are available in the Amp block.")
                    .foregroundStyle(.secondary).padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(AM4Appearance.panel)
        .task(id: page) {
            if blockID == 0x3A { await midi.showAmpPage(page) }
        }
        .onDisappear {
            if blockID == 0x3A { Task { await midi.showAmpPage(nil) } }
        }
    }

    private var ampSelectionMenus: some View {
        HStack(spacing: 12) {
            if let current = midi.ampControls {
                let identity = ParameterEditorState.amp(current).menuIdentity
                AM4Dropdown(title: "Type", accessibilityName: "Amp type", choices: AM4MenuChoices.ampTypes,
                    selected: String(current.model), identity: identity) { id in
                        if let model = Int(id) { select(AM4AmpSelection(context: current.context, expectedModel: current.model, model: model)) }
                    }.equatable().frame(maxWidth: 280)
                AM4Dropdown(title: "Library", accessibilityName: "Amp library", choices: AM4MenuChoices.ampLibrary,
                    selected: nil, placeholder: "Choose preset…", identity: identity) { id in
                        select(AM4AmpSelection(context: current.context, expectedModel: current.model, libraryID: id))
                    }.equatable().frame(maxWidth: 220)
            } else { ProgressView("Reading amp…").controlSize(.small) }
        }
        .disabled(midi.ampControls?.context.channel == nil || !midi.isConnected || midi.isApplyingGain || midi.isNavigating || midi.isLoadingPresets)
        .alert("Amp selection failed", isPresented: Binding(
            get: { selectionFailure != nil }, set: { if !$0 { selectionFailure = nil } })) {
                Button("OK", role: .cancel) { selectionFailure = nil }
            } message: { Text(selectionFailure ?? "Refresh the Amp controls and try again.") }
    }

    private func select(_ command: AM4AmpSelection) {
        Task {
            do { try await midi.selectAmp(command) }
            catch { selectionFailure = error.localizedDescription }
        }
    }

    private func sections(_ controls: [AM4AmpControl]) -> [AmpControlSection] {
        var result: [AmpControlSection] = []
        for control in controls {
            if let index = result.firstIndex(where: { $0.id == control.section }) {
                result[index].controls.append(control)
            } else { result.append(AmpControlSection(id: control.section, controls: [control])) }
        }
        return result
    }
}

private struct AmpControlSection: Identifiable {
    let id: String
    var controls: [AM4AmpControl]
}

private struct AmpParameterRow: View {
    @ObservedObject var midi: AM4Connection
    let control: AM4AmpControl
    let definition: AM4ParameterDefinition
    let actual: AM4ParameterValue
    let state: ParameterEditorState
    private let isEQFader: Bool
    @State private var normalized = 0.0
    @State private var dragStart = 0.0
    @State private var editing = false
    @State private var expected: AM4ParameterValue?
    @State private var expectedState: ParameterEditorState?
    @State private var submitting = false
    @State private var failure: String?
    @State private var numberEditor = false
    @State private var pendingSwitch: Bool?
    private let dialAccent = AM4Appearance.accent

    init(midi: AM4Connection, control: AM4AmpControl, definition: AM4ParameterDefinition, actual: AM4ParameterValue, state: AM4AmpControls) {
        self.midi = midi; self.control = control; self.definition = definition; self.actual = actual; self.state = .amp(state); self.isEQFader = false
    }
    init(midi: AM4Connection, control: AM4AmpControl, definition: AM4ParameterDefinition, actual: AM4ParameterValue, effectState: AM4EffectControls) {
        self.midi = midi; self.control = control; self.definition = definition; self.actual = actual; self.state = .effect(effectState); self.isEQFader = false
    }
    init(midi: AM4Connection, control: AM4AmpControl, definition: AM4ParameterDefinition, actual: AM4ParameterValue, eqState: ParameterEditorState) {
        self.midi = midi; self.control = control; self.definition = definition; self.actual = actual
        self.state = eqState; self.isEQFader = true
    }
    private var currentValues: [String: AM4ParameterValue]? {
        switch state { case .amp: return midi.ampControls?.values; case .effect: return midi.effectControls?.values }
    }
    var body: some View {
        VStack(spacing: 12) {
            Text(control.label.replacingOccurrences(of: "\n", with: " "))
                .font((isEQFader ? Font.caption : .subheadline).weight(.semibold)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .bottom)
            if definition.isDiscrete {
                enumControl.frame(maxWidth: .infinity, minHeight: 110)
            } else {
                Group {
                    if isEQFader {
                        EQFader(position: normalized, zero: definition.normalizedValue(forDisplay: 0) ?? 0.5, accent: dialAccent)
                            .frame(height: EQFader.height).contentShape(Rectangle())
                    } else {
                        RotaryKnob(position: normalized, accent: dialAccent)
                            .frame(width: 94, height: 94).contentShape(Circle())
                    }
                }.am4ControlHover()
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { gesture in
                            if !editing {
                                editing = true; dragStart = actual.normalized
                                expected = actual; expectedState = state; failure = nil
                            }
                            let distance = -gesture.translation.height * (isEQFader ? 240 / EQFader.travel : 1)
                            normalized = definition.position(afterDragging: distance, from: dragStart)
                        }
                        .onEnded { _ in
                            editing = false
                            guard let expected, let origin = expectedState else { return }
                            submit(origin.edit(key: definition.key, expected: expected, normalized: normalized))
                        })
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        submit(state.edit(key: definition.key, expected: actual, resetToDefault: true))
                    })
                    .accessibilityElement().accessibilityLabel(control.label)
                    .accessibilityValue(actual.text)
                    .accessibilityHint("Drag up or down. Double-tap to reset to the model’s default.")
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 0.01 : -0.01
                        submit(state.edit(key: definition.key, expected: actual, normalized: min(1, max(0, actual.normalized + delta))))
                    }
                    .accessibilityAction(named: "Reset to default") {
                        submit(state.edit(key: definition.key, expected: actual, resetToDefault: true))
                    }
                Button {
                    expected = actual; expectedState = state; failure = nil; numberEditor = true
                } label: {
                    Text(editing ? definition.preview(normalized) : actual.text)
                        .font(.system(isEQFader ? .caption : .title3, design: .monospaced).weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.55)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(AM4ButtonStyle()).accessibilityLabel("Type \(control.label) value")
                    .popover(isPresented: $numberEditor) {
                        ParameterNumberEditor(definition: definition, label: control.label,
                                              initialPosition: expected?.normalized ?? actual.normalized) { value in
                            guard let expected, let origin = expectedState else { return }
                            numberEditor = false
                            normalized = value
                            submit(origin.edit(key: definition.key, expected: expected, normalized: value))
                        }.presentationCompactAdaptation(.popover)
                    }
            }
            if let failure { Text(failure).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .disabled(submitting || midi.isApplyingGain || midi.isNavigating || state.locked(control))
            .onAppear { normalized = actual.normalized }
            .onChange(of: actual) { _, value in
                if !editing && !submitting { normalized = value.normalized }
            }
    }

    @ViewBuilder private var enumControl: some View {
        if state.usesSwitch(control) {
            VStack(spacing: 16) {
                Toggle(control.label, isOn: Binding(
                    get: { pendingSwitch ?? (definition.ordinal(actual) == 1) },
                    set: setSwitch))
                    .labelsHidden().toggleStyle(.switch).tint(AM4Appearance.accent)
                    .scaleEffect(1.8).frame(width: 104, height: 64).am4ControlHover()
                    .accessibilityLabel(control.label)
                    .accessibilityValue(actual.text)
                    .disabled(!(0...1).contains(definition.ordinal(actual)))
                Text(actual.text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        } else if !definition.dynamic, !definition.choices.isEmpty, definition.ordinal(actual) < definition.choices.count {
            Picker(control.label, selection: Binding(get: { definition.ordinal(actual) }, set: { ordinal in
                guard ordinal != definition.ordinal(actual) else { return }
                submit(state.edit(key: definition.key, expected: actual, ordinal: ordinal))
            })) {
                ForEach(Array(definition.choices.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
            }.labelsHidden().pickerStyle(.menu).controlSize(.regular)
                .frame(maxWidth: .infinity, minHeight: 38).am4ControlHover().accessibilityLabel(control.label)
                .id("\(state.menuIdentity):\(definition.key):\(actual.raw):\(actual.normalized):\(actual.text)")
        } else {
            VStack(spacing: 14) {
                Text(actual.text).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                HStack {
                    Button { nudge(-1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 36) }
                        .disabled(definition.ordinal(actual) == 0).accessibilityLabel("Previous \(control.label) choice")
                    Spacer(minLength: 4)
                    Button { nudge(1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 36) }
                        .accessibilityLabel("Next \(control.label) choice")
                }.buttonStyle(AM4NativeButtonStyle()).tint(dialAccent)
            }
        }
    }
    private func setSwitch(_ on: Bool) {
        let target = on ? 1 : 0
        let current = definition.ordinal(actual)
        guard target != current, (0...1).contains(current) else { return }
        pendingSwitch = on
        if definition.dynamic {
            // Preserve the firmware-owned choice list and the existing,
            // verified single-step operation for model-dependent switches.
            nudge(target - current)
        } else {
            submit(state.edit(key: definition.key, expected: actual, ordinal: target))
        }
    }
    private func nudge(_ direction: Int) {
        submit(state.edit(key: definition.key, expected: actual, direction: direction))
    }
    private func submit(_ edit: ParameterEditorEdit) {
        guard !submitting else { return }
        submitting = true; failure = nil
        Task {
            do {
                switch edit {
                case .amp(let command): try await midi.changeAmpParameter(command)
                case .effect(let command): try await midi.changeEffectParameter(command)
                }
            }
            catch { failure = error.localizedDescription }
            if failure == nil, let requested = pendingSwitch,
               let confirmed = currentValues?[definition.key],
               definition.ordinal(confirmed) != (requested ? 1 : 0) {
                failure = "AM4 kept its previous switch state. Try again."
            }
            submitting = false
            pendingSwitch = nil
            normalized = currentValues?[definition.key]?.normalized ?? actual.normalized
            expected = nil; expectedState = nil
        }
    }
}

private extension AM4ParameterDefinition {
    var isGraphicEQBand: Bool {
        (block == 58 && (62...69).contains(parameter)) ||
        (block == 50 && (10...19).contains(parameter))
    }
}

private struct EQBandStrip: View {
    @ObservedObject var midi: AM4Connection
    let controls: [AM4AmpControl]
    let state: ParameterEditorState

    private func definition(_ key: String) -> AM4ParameterDefinition? {
        switch state {
        case .amp: return AM4AmpCatalog.shared.definition(key)
        case .effect(let value): return AM4EffectsCatalog.shared.effect(value.context.block)?.definition(key)
        }
    }
    private var identity: String {
        switch state {
        case .amp(let value): return "\(value.context.location):\(value.context.scene):\(value.context.channel ?? -1):\(value.model)"
        case .effect(let value): return "\(value.context.location):\(value.context.scene):\(value.context.channel):\(value.model)"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let first = controls.first, let definition = definition(first.key) {
                VStack(spacing: 12) {
                    Text("dB").font(.caption2).foregroundStyle(.tertiary)
                        .frame(height: 40, alignment: .bottom)
                    GeometryReader { geometry in
                        ForEach(0..<5) { index in
                            let value = definition.displayValue(1 - Double(index) / 4)
                            Text(value > 0 ? String(format: "+%g", value) : String(format: "%g", value))
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(index == 2 ? .cyan : .secondary)
                                .position(x: geometry.size.width / 2, y: 12 + EQFader.travel * Double(index) / 4)
                        }
                    }.frame(height: EQFader.height)
                }.frame(width: 28)
            }
            ForEach(controls) { control in
                if let definition = definition(control.key), let actual = state.values[control.key] {
                    AmpParameterRow(midi: midi, control: control, definition: definition, actual: actual, eqState: state)
                        .frame(minWidth: 44, maxWidth: .infinity)
                        .id("\(identity):\(control.id)")
                }
            }
        }.padding(16)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07)))
    }
}

private struct EQFader: View {
    static let height: CGFloat = 220
    static let travel: CGFloat = height - 24
    let position: Double
    let zero: Double
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            let center = geometry.size.width / 2
            let y = 12 + (1 - min(1, max(0, position))) * Self.travel
            let zeroY = 12 + (1 - zero) * Self.travel
            ZStack {
                ForEach(0..<9) { index in
                    Rectangle().fill(.white.opacity(index == 4 ? 0.3 : 0.09))
                        .frame(height: 1)
                        .position(x: center, y: 12 + Self.travel * Double(index) / 8)
                }
                RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.65))
                    .frame(width: 6, height: Self.travel).position(x: center, y: Self.height / 2)
                Capsule().fill(accent.opacity(0.8))
                    .frame(width: 3, height: max(2, abs(y - zeroY))).position(x: center, y: (y + zeroY) / 2)
                Rectangle().fill(accent.opacity(0.6)).frame(height: 1).position(x: center, y: zeroY)
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(white: 0.4), Color(white: 0.19)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.2)))
                    .overlay { Capsule().fill(accent).frame(height: 2).padding(.horizontal, 5) }
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .frame(width: min(44, max(28, geometry.size.width - 8)), height: 24)
                    .position(x: center, y: y)
            }
        }
    }
}

private struct RotaryKnob: View {
    let position: Double
    let accent: Color
    var body: some View {
        ZStack {
            Circle().fill(.black).shadow(color: .black.opacity(0.5), radius: 5, y: 3)
            Circle().trim(from: 0, to: 0.75).stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .rotationEffect(.degrees(135)).padding(3)
            Circle().trim(from: 0, to: max(0.001, min(1, position)) * 0.75)
                .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .rotationEffect(.degrees(135)).padding(3)
            Circle().fill(LinearGradient(colors: [Color(white: 0.31), Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(11).overlay { Circle().stroke(.white.opacity(0.12), lineWidth: 1).padding(12) }
            Capsule().fill(accent).frame(width: 3, height: 24).offset(y: -25)
                .rotationEffect(.degrees(-135 + min(1, max(0, position)) * 270))
            Circle().stroke(.white.opacity(0.15), lineWidth: 1).frame(width: 7, height: 7)
        }
    }
}

private struct ParameterNumberEditor: View {
    let definition: AM4ParameterDefinition
    let label: String
    let initialPosition: Double
    let apply: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(label.replacingOccurrences(of: "\n", with: " ")).font(.headline)
            HStack {
                TextField("Value", text: $text).textFieldStyle(.roundedBorder).am4ControlHover()
                    .font(.system(.title2, design: .monospaced)).focused($focused)
                    .onSubmit(commit)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation).submitLabel(.done)
                    #endif
                if !definition.unit.isEmpty { Text(definition.unit).foregroundStyle(.secondary) }
            }
            Text("\(definition.preview(0)) – \(definition.preview(1))")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(AM4NativeButtonStyle())
                Spacer()
                Button("Apply", action: commit).buttonStyle(AM4NativeButtonStyle(prominent: true)).tint(AM4Appearance.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 300)
            .onAppear {
                text = String(format: "%.6f", definition.displayValue(initialPosition))
                    .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
                focused = true
            }
    }
    private func commit() {
        let decimal = Locale.current.decimalSeparator ?? "."
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: decimal, with: ".")
        guard let value = Double(input), let position = definition.normalizedValue(forDisplay: value) else {
            error = "Enter a number within the range above."
            return
        }
        apply(position)
    }
}


private enum ParameterEditorEdit {
    case amp(AM4AmpEdit)
    case effect(AM4EffectEdit)
}
private enum ParameterEditorState {
    case amp(AM4AmpControls)
    case effect(AM4EffectControls)
    var menuIdentity: String {
        switch self {
        case .amp(let value):
            return "amp:\(value.context.location):\(value.context.scene):\(value.context.channel ?? -1):\(value.context.blocks):\(value.model):\(value.page)"
        case .effect(let value):
            return "effect:\(value.context.location):\(value.context.scene):\(value.context.channel):\(value.context.slot):\(value.context.blocks):\(value.model):\(value.page)"
        }
    }
    var values: [String: AM4ParameterValue] {
        switch self { case .amp(let state): return state.values; case .effect(let state): return state.values }
    }
    func usesSwitch(_ control: AM4AmpControl) -> Bool {
        switch self {
        case .amp: return AM4AmpCatalog.shared.usesSwitch(control, values: values)
        case .effect(let state): return AM4EffectsCatalog.shared.effect(state.context.block)!.usesSwitch(control, values: values)
        }
    }
    func locked(_ control: AM4AmpControl) -> Bool {
        switch self { case .amp: return false; case .effect(let state): return AM4EffectsCatalog.shared.effect(state.context.block)!.locked(control, values: values) }
    }
    func edit(key: String, expected: AM4ParameterValue, normalized: Double? = nil, ordinal: Int? = nil, direction: Int? = nil, resetToDefault: Bool? = nil) -> ParameterEditorEdit {
        switch self {
        case .amp(let state): return .amp(AM4AmpEdit(context: state.context, model: state.model, page: state.page, key: key, expected: expected, normalized: normalized, ordinal: ordinal, direction: direction, resetToDefault: resetToDefault))
        case .effect(let state): return .effect(AM4EffectEdit(state: state, key: key, expected: expected, normalized: normalized, ordinal: ordinal, direction: direction, resetToDefault: resetToDefault))
        }
    }
}

private struct EffectPanel: View {
    @ObservedObject var midi: AM4Connection
    let slot: Int
    let blockID: Int
    let close: () -> Void
    @State private var page = ""
    @State private var failure: String?
    private var effect: AM4EffectDefinition { AM4EffectsCatalog.shared.effect(blockID)! }
    private var activePage: String { page.isEmpty ? effect.pages[0].id : page }
    private var state: AM4EffectControls? {
        guard let state = midi.effectControls, state.context.block == blockID, state.context.slot == slot else { return nil }
        return state
    }
    private var busy: Bool { midi.isApplyingGain || midi.isNavigating || !midi.isConnected }

    var body: some View {
        VStack(spacing: 0) {
            AM4EditorHeader(title: blockID == 119 ? "Drive 2" : effect.name,
                subtitle: state.map { "\(AM4Message.locationLabel($0.context.location)) · Scene \($0.context.scene + 1)" },
                busy: midi.isApplyingGain, close: close) { effectSelectionMenus }
            Divider()
            HStack(spacing: 10) {
                Text("Channel").font(.subheadline).foregroundStyle(.secondary)
                if let state {
                    ForEach(0..<4) { index in
                        Button { select(AM4EffectSelection(state: state, channel: index)) } label: {
                            Text(String(UnicodeScalar(65 + index)!)).font(.headline)
                                .foregroundStyle(state.context.channel == index ? AM4Appearance.accent : .secondary)
                                .frame(width: 48, height: 36)
                                .background(state.context.channel == index ? AM4Appearance.accent.opacity(0.16) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(state.context.channel == index ? AM4Appearance.accent.opacity(0.65) : .clear))
                        }.buttonStyle(AM4ButtonStyle()).accessibilityLabel("\(effect.name) channel \(String(UnicodeScalar(65 + index)!))")
                            .accessibilityAddTraits(state.context.channel == index ? [.isSelected] : [])
                    }
                } else { ProgressView().controlSize(.small) }
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 10).disabled(busy)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(effect.pages) { item in
                            Button { page = item.id } label: {
                                Text(item.title).font(.headline).foregroundStyle(activePage == item.id ? .white : .secondary)
                                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).padding(.horizontal, 18)
                                    .background(activePage == item.id ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(alignment: .leading) { if activePage == item.id { Capsule().fill(AM4Appearance.accent).frame(width: 3).padding(.vertical, 12) } }
                            }.buttonStyle(AM4ButtonStyle())
                        }
                    }.padding(.vertical, 14).padding(.horizontal, 8)
                }.frame(width: 148).background(.white.opacity(0.025)).disabled(busy)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let state, state.page == activePage {
                            let controls = effect.controls(page: activePage, values: state.values)
                            let bands = controls.filter { effect.definition($0.key)?.isGraphicEQBand == true }
                            if !bands.isEmpty { EQBandStrip(midi: midi, controls: bands, state: .effect(state)) }
                            ForEach(sections(controls.filter { effect.definition($0.key)?.isGraphicEQBand != true })) { group in
                                VStack(alignment: .leading, spacing: 18) {
                                    if group.id.caseInsensitiveCompare(activePage) != .orderedSame {
                                        Text(group.id.replacingOccurrences(of: "_", with: " ")).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                                    }
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 18)], alignment: .leading, spacing: 28) {
                                        ForEach(group.controls) { control in
                                            if let definition = effect.definition(control.key), let actual = state.values[control.key] {
                                                VStack(spacing: 4) {
                                                    AmpParameterRow(midi: midi, control: control, definition: definition, actual: actual, effectState: state)
                                                    if effect.locked(control, values: state.values) {
                                                        Label("Tempo synced", systemImage: "metronome").font(.caption2).foregroundStyle(.secondary)
                                                    }
                                                }.id("\(state.context.location):\(state.context.scene):\(state.context.channel):\(state.model):\(control.id)")
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            ProgressView("Reading \(effect.name) controls…").frame(maxWidth: .infinity, minHeight: 180)
                            if !midi.gainStatus.isEmpty { Text(midi.gainStatus).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Divider()
            HStack {
                Text(midi.gainStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Drag to adjust · Tap a number to type · Double-tap to reset").font(.caption2).foregroundStyle(.tertiary)
                Button { loadPage() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(AM4NativeButtonStyle()).accessibilityLabel("Refresh controls").disabled(busy)
            }.padding(.horizontal, 20).padding(.vertical, 8)
        }.background(AM4Appearance.panel)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12)))
            .onAppear(perform: loadPage).onChange(of: page) { _, _ in loadPage() }
            .onDisappear { Task { try? await midi.showEffectPage(AM4EffectPageSelection(slot: slot, block: blockID, page: nil)) } }
            .alert("\(effect.name) update failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "Refresh the block and try again.") }
    }
    private var effectSelectionMenus: some View {
        HStack(spacing: 12) {
            if let state {
                let identity = ParameterEditorState.effect(state).menuIdentity
                AM4Dropdown(title: "Type", accessibilityName: "\(effect.name) type", choices: AM4MenuChoices.effectTypes[effect.block] ?? [],
                    selected: String(state.model), identity: identity) { id in
                        if let model = Int(id) { select(AM4EffectSelection(state: state, model: model)) }
                    }.equatable().frame(maxWidth: 280)
                AM4Dropdown(title: "Library", accessibilityName: "\(effect.name) library", choices: AM4MenuChoices.effectLibraries[effect.block] ?? [],
                    selected: nil, placeholder: "Choose preset…", identity: identity) { id in
                        select(AM4EffectSelection(state: state, libraryID: id))
                    }.equatable().frame(maxWidth: 220)
            } else { ProgressView("Reading controls…").controlSize(.small) }
        }.disabled(busy || state == nil || midi.isLoadingPresets)
    }
    private func loadPage() {
        Task {
            do { try await midi.showEffectPage(AM4EffectPageSelection(slot: slot, block: blockID, page: activePage)) }
            catch { failure = error.localizedDescription }
        }
    }
    private func select(_ command: AM4EffectSelection) {
        Task { do { try await midi.selectEffect(command) } catch { failure = error.localizedDescription } }
    }
    private func sections(_ controls: [AM4AmpControl]) -> [AmpControlSection] {
        var result: [AmpControlSection] = []
        for control in controls {
            if let index = result.firstIndex(where: { $0.id == control.section }) { result[index].controls.append(control) }
            else { result.append(AmpControlSection(id: control.section, controls: [control])) }
        }
        return result
    }
}


/// A navigation split owns the Mac window's toolbar/titlebar. The remote is an
/// overlay inside Mac Jams, so use a content-only split on Mac and keep the
/// original adaptive preset navigation on iPad.
private struct AM4WorkspaceSplit<Sidebar: View, Detail: View>: View {
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail
    var body: some View {
        #if os(macOS)
        HSplitView {
            sidebar()
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 450)
                .background(AM4Appearance.panel)
            detail().frame(minWidth: 320, maxWidth: .infinity)
        }
        #else
        NavigationSplitView {
            sidebar().navigationTitle("AM4 Remote")
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            detail().navigationTitle("")
        }
        #endif
    }
}
