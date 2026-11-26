import JamDesignKit
import SwiftUI
import LooperCore

struct LooperPanel: View {
    @ObservedObject var model: LooperModel
    var fillsHeight = false
    var compact = false
    @State private var showingSavedLoops = false
    private let accent = JamDesign.accent
    private var bars: Binding<Double> { Binding(get: { Double(model.bars) }, set: { if $0.isFinite { model.bars = Int(min(8, max(1, $0.rounded()))) } }) }
    private var threshold: Binding<Double> { Binding(get: { model.thresholdDB }, set: { if $0.isFinite { model.thresholdDB = min(0, max(-72, $0)) } }) }
    private var stateColor: Color {
        switch Int(model.state) { case TL_RECORDING: JamDesign.recording; case TL_ARMED, TL_WAITING: JamDesign.armed; case TL_PLAYING: JamDesign.playing; default: JamDesign.secondary }
    }
    private var stateName: String {
        switch Int(model.state) { case TL_RECORDING: "Recording"; case TL_ARMED: "Armed"; case TL_WAITING: "Waiting"; case TL_PLAYING: "Playing"; case TL_STOPPED: "Stopped"; default: "Empty" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            LoopWaveform(telemetry: model.telemetry, bars: model.bars, stateColor: stateColor,
                         showsProgress: model.hasLoop || model.state == TL_RECORDING).frame(height: compact ? 50 : 56)
        }.frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
            .jamSurface(border: model.busy || model.hasLoop ? stateColor.opacity(0.4) : JamDesign.border)
            .tint(accent)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { JamModuleTitle("Looper", icon: "arrow.triangle.2.circlepath"); Spacer(minLength: 4); volume }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    timing.fixedSize()
                    transport.fixedSize()
                    Spacer(minLength: 4)
                    stateBadge.fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { timing; Spacer(minLength: 4); stateBadge }
                    transport
                }
            }
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                LoopDetail(model: model)
                HStack(spacing: 10) {
                    Text("Threshold").font(.caption).foregroundStyle(.secondary)
                    LoopInputMeter(telemetry: model.telemetry, threshold: model.thresholdDB)
                    TextField("dB", value: threshold, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.plain).jamNumberField(width: 48).multilineTextAlignment(.trailing).accessibilityLabel("Threshold decibels")
                    Text("dB").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var stateBadge: some View {
        Text(stateName).font(.caption.weight(.semibold)).foregroundStyle(stateColor)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(stateColor.opacity(0.1), in: Capsule())
    }
    private var timing: some View {
        HStack(spacing: 10) { barsControl; timingSummary }
    }
    private var barsControl: some View {
        TimingControl(label: "Bars", value: bars, bounds: 1...8, accessibilityName: "Loop bars")
            .disabled(!model.canEditTiming).fixedSize()
    }
    private var timingDivider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 24).accessibilityHidden(true)
    }
    private var timingSummary: some View {
        Text(String(format: "%.2f s", model.seconds))
            .font(.system(size: 13, weight: .regular).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
    }
    private var transport: some View {
        HStack(spacing: 8) {
            armButton; recordButton; playButton; clearButton
            Button { Task { await model.saveLoop() } } label: { transportIcon("square.and.arrow.down") }
                .disabled(!model.canSave).help("Save loop…").accessibilityLabel("Save loop")
            Button { showingSavedLoops.toggle() } label: { transportIcon("folder") }
                .disabled(!model.canRecall).help("Open saved loop…").accessibilityLabel("Open saved loop")
                .anchorPreference(key: JamDropdownPopupKey.self, value: .bounds) { anchor in
                    showingSavedLoops ? JamDropdownRequest(anchor: anchor, title: "Saved loops",
                        content: AnyView(SavedLoopBrowser(model: model, close: { showingSavedLoops = false })),
                        close: { showingSavedLoops = false }, width: 380, height: 420, prefersAbove: true, opensBeside: true) : nil
                }
        }
            .buttonStyle(JamIconStyle())
    }
    private var armButton: some View {
        Button { Task { await model.arm() } } label: {
            transportIcon("record.circle").foregroundStyle(model.state == TL_ARMED ? JamDesign.armed : JamDesign.text)
        }
                .disabled(!model.canEditTiming || model.input == nil || model.output == nil)
                .help("Arm loop: start recording at the input threshold")
                .accessibilityLabel("Arm loop")
    }
    private var recordButton: some View {
        Button { Task { await model.record() } } label: {
                transportIcon(model.state == TL_RECORDING ? "stop.circle" : "record.circle.fill")
                    .foregroundStyle(model.state == TL_RECORDING ? JamDesign.recording : JamDesign.text)
            }.disabled(!model.canRecord || model.input == nil || model.output == nil)
                .help(model.state == TL_RECORDING ? "Finish recording and loop now" : "Record immediately without waiting for a strum")
                .accessibilityLabel(model.state == TL_RECORDING ? "Finish recording" : "Record")
    }
    private var playButton: some View {
        Button { model.playStop() } label: {
                transportIcon(model.state == TL_PLAYING || model.state == TL_WAITING || model.busy ? "stop.fill" : "play.fill")
            }.disabled((!model.hasLoop && !model.busy) || !model.controlsAvailable)
                .help(model.state == TL_WAITING ? "Cancel queued loop" : model.state == TL_PLAYING || model.busy ? "Stop loop" : "Play loop")
                .accessibilityLabel(model.state == TL_PLAYING || model.state == TL_WAITING || model.busy ? "Stop loop" : "Play loop")
    }
    private var clearButton: some View {
        Button { model.clear() } label: { transportIcon("trash") }.disabled((!model.running && !model.audioPaused) || model.state == TL_EMPTY || !model.controlsAvailable)
            .help("Clear loop").accessibilityLabel("Clear loop")
    }
    private func transportIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .regular)).contentShape(Rectangle())
    }
    private var volume: some View { VolumeControl(volume: $model.volume, name: "Loop") }
}

struct TempoControl: View {
    @ObservedObject var model: LooperModel
    let context: String
    var iconOnly = false

    var body: some View {
        TimingControl(label: "BPM", labelIcon: iconOnly ? "metronome" : nil, value: $model.bpm, bounds: 30...240, accessibilityName: "\(context) tempo")
            .disabled(!model.canEditTiming)
    }
}

private struct TimingControl: View {
    let label: String
    let labelIcon: String?
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let accessibilityName: String
    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    init(label: String, labelIcon: String? = nil, value: Binding<Double>, bounds: ClosedRange<Double>, accessibilityName: String) {
        self.label = label
        self.labelIcon = labelIcon
        self._value = value
        self.bounds = bounds
        self.accessibilityName = accessibilityName
        self._draft = State(initialValue: value.wrappedValue.formatted(.number.precision(.fractionLength(0))))
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "minus").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: JamDesign.target) }
                .disabled(value <= bounds.lowerBound).accessibilityLabel("Decrease \(label)")
                .help("Decrease \(label)")
            TextField(label, text: $draft)
                .textFieldStyle(.plain).multilineTextAlignment(.center)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .frame(width: label == "BPM" ? 42 : 28, height: JamDesign.target)
                .focused($focused)
                .accessibilityLabel(accessibilityName)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onChange(of: draft) { _, _ in
                    // Keep empty/partial text local while replacing a number.
                    // Only complete, valid values update the shared timing.
                    guard enabled, focused, let parsed, bounds.contains(parsed), value != parsed else { return }
                    value = parsed
                }
                .onChange(of: value) { _, next in
                    // Reflect the other tempo control and song selection without
                    // rewriting the text/caret during this field's own edit.
                    if !focused || parsed != next { draft = formatted(next) }
                }
                .onChange(of: enabled) { _, isEnabled in
                    if !isEnabled { draft = formatted(value); focused = false }
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                    guard enabled, focused else { return .ignored }
                    step(key.key == .upArrow ? 1 : -1)
                    return .handled
                }
            Group {
                if let labelIcon {
                    Image(systemName: labelIcon).accessibilityHidden(true)
                } else {
                    Text(label)
                }
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(JamDesign.secondary).padding(.trailing, 7)
            Button { step(1) } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: JamDesign.target) }
                .disabled(value >= bounds.upperBound).accessibilityLabel("Increase \(label)")
                .help("Increase \(label)")
        }.buttonStyle(JamPlainButtonStyle())
            .background(JamDesign.control, in: RoundedRectangle(cornerRadius: 8))
    }

    private var parsed: Double? {
        guard let number = try? Double(draft, format: .number), number.isFinite else { return nil }
        return number
    }
    private func formatted(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0)))
    }
    private func commit() {
        if enabled, let parsed { value = min(bounds.upperBound, max(bounds.lowerBound, parsed)) }
        draft = formatted(value)
    }
    private func step(_ delta: Double) {
        guard enabled else { return }
        value = min(bounds.upperBound, max(bounds.lowerBound, value.rounded() + delta))
        draft = formatted(value)
    }
}

private struct LoopDetail: View {
    @ObservedObject var model: LooperModel
    var body: some View {
        Text(model.detail).font(.caption).foregroundStyle(JamDesign.secondary)
            .lineLimit(2, reservesSpace: true)
            .padding(.top, 4).padding(.bottom, -4)
    }
}

private struct LoopInputMeter: View {
    let telemetry: LoopTelemetry
    let threshold: Double

    var body: some View {
        let level = telemetry.meterDB
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(JamDesign.accent.opacity(0.65)).frame(width: max(0, geo.size.width * min(1, max(0, (level + 72) / 72))))
                Rectangle().fill(.orange).frame(width: 2).offset(x: min(geo.size.width - 2, max(0, geo.size.width * (threshold + 72) / 72)))
            }
        }.frame(height: 8).accessibilityLabel("Input level \(Int(level)) decibels")
    }
}

private struct LoopWaveform: View {
    let telemetry: LoopTelemetry
    let bars: Int
    let stateColor: Color
    let showsProgress: Bool

    var body: some View {
        let waveform = telemetry.waveform, progress = telemetry.progress
        return Canvas { context, size in
            for bar in 0...bars {
                let x = size.width * Double(bar) / Double(bars)
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            let mid = size.height / 2
            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: mid)); baseline.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(baseline, with: .color(.white.opacity(0.1)), lineWidth: 1)
            var peaks = Path()
            for (i, value) in waveform.enumerated() where value > 0 {
                let x = size.width * (Double(i) + 0.5) / 256, h = max(1, min(1, Double(value)) * mid)
                peaks.move(to: CGPoint(x: x, y: mid - h)); peaks.addLine(to: CGPoint(x: x, y: mid + h))
            }
            context.stroke(peaks, with: .color(stateColor.opacity(0.9)), lineWidth: 2)
            if showsProgress {
                let x = size.width * min(1, max(0, progress))
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(p, with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
        }.accessibilityLabel("Loop waveform")
    }
}
