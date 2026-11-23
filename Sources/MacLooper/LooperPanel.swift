import SwiftUI
import LooperCore

struct LooperPanel: View {
    @ObservedObject var model: LooperModel
    var availableHeight: Double = 208
    var minimumHeightChanged: (Double) -> Void = { _ in }
    @State private var controlsHeight = 133.0
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    private var bars: Binding<Double> { Binding(get: { Double(model.bars) }, set: { if $0.isFinite { model.bars = Int(min(8, max(1, $0.rounded()))) } }) }
    private var threshold: Binding<Double> { Binding(get: { model.thresholdDB }, set: { if $0.isFinite { model.thresholdDB = min(0, max(-72, $0)) } }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls.onGeometryChange(for: Double.self) { $0.size.height } action: {
                controlsHeight = $0
                minimumHeightChanged(ceil($0) + 74) // Padding, spacing, and a 32-point waveform.
            }
            waveform.frame(height: max(32, availableHeight - controlsHeight - 42))
        }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            .background(Color(red: 0.075, green: 0.085, blue: 0.10)).tint(accent)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { title; Spacer(minLength: 8); volume }
            VStack(alignment: .leading, spacing: 14) {
                timing
                transport
            }.padding(.bottom, 6)
            if model.busy || model.hasLoop {
                HStack(spacing: 8) {
                    Text(model.status).font(.caption.weight(.medium)).foregroundStyle(model.state == TL_RECORDING ? .red : accent)
                    Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Text("Threshold").font(.caption).foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(accent.opacity(0.65)).frame(width: max(0, geo.size.width * min(1, max(0, (model.meterDB + 72) / 72))))
                        Rectangle().fill(.orange).frame(width: 2).offset(x: min(geo.size.width - 2, max(0, geo.size.width * (model.thresholdDB + 72) / 72)))
                    }
                }.frame(height: 8).accessibilityLabel("Input level \(Int(model.meterDB)) decibels")
                TextField("dB", value: threshold, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.plain).jamNumberField(width: 48).multilineTextAlignment(.trailing).accessibilityLabel("Threshold decibels")
                Text("dB").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var waveform: some View {
            Canvas { context, size in
                for bar in 0...model.bars {
                    let x = size.width * Double(bar) / Double(model.bars)
                    var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
                }
                let mid = size.height / 2
                var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: mid)); baseline.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(baseline, with: .color(.white.opacity(0.1)), lineWidth: 1)
                for (i, value) in model.waveform.enumerated() where value > 0 {
                    let x = size.width * (Double(i) + 0.5) / 256, h = max(1, min(1, Double(value)) * mid)
                    var p = Path(); p.move(to: CGPoint(x: x, y: mid - h)); p.addLine(to: CGPoint(x: x, y: mid + h))
                    context.stroke(p, with: .color(model.state == TL_RECORDING ? .red : accent.opacity(0.8)), lineWidth: 2)
                }
                if model.hasLoop || model.state == TL_RECORDING {
                    let x = size.width * min(1, max(0, model.progress))
                    var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(p, with: .color(.white.opacity(0.8)), lineWidth: 1)
                }
            }.accessibilityLabel("Loop waveform")
    }
    private var title: some View { Text("Looper").font(.callout.weight(.semibold)).fixedSize() }
    private var timing: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { bpmControl; timingDivider; barsControl; timingDivider; timingSummary }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) { bpmControl; timingDivider; barsControl }
                timingSummary
            }
            VStack(alignment: .leading, spacing: 6) { bpmControl; barsControl; timingSummary }
        }
    }
    private var bpmControl: some View {
        TempoControl(model: model, context: "Loop").fixedSize()
    }
    private var barsControl: some View {
        TimingControl(label: "Bars", value: bars, bounds: 1...8, accessibilityName: "Loop bars")
            .disabled(!model.canEditTiming).fixedSize()
    }
    private var timingDivider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 24).accessibilityHidden(true)
    }
    private var timingSummary: some View {
        Text(String(format: "4/4 · %.2f s", model.seconds))
            .font(.system(size: 13, weight: .regular).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
    }
    private var transport: some View {
        HStack(spacing: 10) { armButton; recordButton; playButton; clearButton }
            .buttonStyle(JamPlainButtonStyle())
    }
    private var armButton: some View {
        Button { Task { await model.arm() } } label: {
            transportIcon("record.circle").foregroundStyle(model.state == TL_ARMED ? accent : .primary)
        }
                .disabled(!model.canEditTiming || model.input == nil || model.output == nil)
                .help("Arm loop: start recording at the input threshold")
                .accessibilityLabel("Arm loop")
    }
    private var recordButton: some View {
        Button { Task { await model.record() } } label: {
                transportIcon(model.state == TL_RECORDING ? "stop.circle" : "record.circle.fill")
                    .foregroundStyle(model.state == TL_RECORDING ? .red : .primary)
            }.disabled(!model.canRecord || model.input == nil || model.output == nil)
                .help(model.state == TL_RECORDING ? "Finish recording and loop now" : "Record immediately without waiting for a strum")
                .accessibilityLabel(model.state == TL_RECORDING ? "Finish recording" : "Record")
    }
    private var playButton: some View {
        Button { model.playStop() } label: {
                transportIcon(model.state == TL_PLAYING || model.busy ? "stop.fill" : "play.fill")
            }.disabled(!model.hasLoop && !model.busy)
                .help(model.state == TL_PLAYING || model.busy ? "Stop loop" : "Play loop")
                .accessibilityLabel(model.state == TL_PLAYING || model.busy ? "Stop loop" : "Play loop")
    }
    private var clearButton: some View {
        Button { model.clear() } label: { transportIcon("trash") }.disabled((!model.running && !model.audioPaused) || model.state == TL_EMPTY)
            .help("Clear loop").accessibilityLabel("Clear loop")
    }
    private func transportIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 20)).frame(width: 36, height: 36).contentShape(Rectangle())
    }
    private var volume: some View { VolumeControl(volume: $model.volume, name: "Loop") }
}

struct TempoControl: View {
    @ObservedObject var model: LooperModel
    let context: String

    var body: some View {
        TimingControl(label: "BPM", value: $model.bpm, bounds: 30...240, accessibilityName: "\(context) tempo")
            .disabled(!model.canEditTiming)
    }
}

private struct TimingControl: View {
    let label: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let accessibilityName: String
    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var stepButtonHeight: CGFloat?

    init(label: String, value: Binding<Double>, bounds: ClosedRange<Double>, accessibilityName: String) {
        self.label = label
        self._value = value
        self.bounds = bounds
        self.accessibilityName = accessibilityName
        self._draft = State(initialValue: value.wrappedValue.formatted(.number.precision(.fractionLength(0))))
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, text: $draft)
                .textFieldStyle(.plain).multilineTextAlignment(.center)
                .jamNumberField(width: label == "BPM" ? 48 : 32, height: stepButtonHeight ?? 26, fontSize: 14, horizontalPadding: 4)
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
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Button { step(-1) } label: { Image(systemName: "minus").font(.system(size: 12, weight: .semibold)).frame(width: 14, height: 18) }
                .disabled(value <= bounds.lowerBound).accessibilityLabel("Decrease \(label)")
                .help("Decrease \(label)")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepButtonHeight = $0 }
            Button { step(1) } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 14, height: 18) }
                .disabled(value >= bounds.upperBound).accessibilityLabel("Increase \(label)")
                .help("Increase \(label)")
        }.buttonStyle(JamButtonStyle()).controlSize(.small)
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
