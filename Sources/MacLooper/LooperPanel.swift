import SwiftUI
import LooperCore

struct LooperPanel: View {
    @ObservedObject var model: LooperModel
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    private var bpm: Binding<Double> { Binding(get: { model.bpm }, set: { if $0.isFinite { model.bpm = min(240, max(30, $0)) } }) }
    private var threshold: Binding<Double> { Binding(get: { model.thresholdDB }, set: { if $0.isFinite { model.thresholdDB = min(0, max(-72, $0)) } }) }
    private var percent: Binding<Double> { Binding(get: { (model.volume * 100).rounded() }, set: { if $0.isFinite { model.volume = min(100, max(0, $0)) / 100 } }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.state == TL_RECORDING ? .red : model.busy ? .orange : accent).frame(width: 7, height: 7)
                Text(model.status).font(.callout.weight(.semibold))
                Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text("GUITAR LOOP").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    TextField("BPM", value: bpm, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).frame(width: 57).accessibilityLabel("Loop tempo")
                    Text("BPM").font(.caption).foregroundStyle(.secondary)
                }.disabled(!model.canEditTiming)
                Picker("Bars", selection: $model.bars) { Text("2 bars").tag(2); Text("4 bars").tag(4); Text("8 bars").tag(8) }
                    .pickerStyle(.segmented).frame(maxWidth: 230).disabled(!model.canEditTiming).labelsHidden()
                Text(String(format: "4/4 · %.2f s", model.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
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
                Slider(value: threshold, in: -72...0).frame(minWidth: 100, maxWidth: 180).accessibilityLabel("Strum threshold")
                TextField("dB", value: threshold, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(width: 48).multilineTextAlignment(.trailing).accessibilityLabel("Threshold decibels")
                Text("dB").font(.caption).foregroundStyle(.secondary)
            }
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
            }.frame(height: 38).accessibilityLabel("Loop waveform")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { transport; Spacer(minLength: 16); volume }
                VStack(spacing: 8) { HStack { transport; Spacer() }; volume }
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
        }.padding(16).background(Color(red: 0.075, green: 0.085, blue: 0.10)).tint(accent)
    }
    private var transport: some View {
        HStack(spacing: 8) {
            Button { Task { await model.arm() } } label: { Label("Arm", systemImage: "record.circle").frame(minWidth: 55) }
                .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                .disabled(!model.canEditTiming || model.input == nil || model.output == nil)
            Button { model.playStop() } label: {
                Label(model.state == TL_PLAYING || model.busy ? "Stop" : "Play", systemImage: model.state == TL_PLAYING || model.busy ? "stop.fill" : "play.fill").frame(minWidth: 50)
            }.disabled(!model.hasLoop && !model.busy)
            Button { model.clear() } label: { Label("Clear", systemImage: "trash") }.disabled(!model.running || model.state == TL_EMPTY)
        }.buttonStyle(.bordered).controlSize(.large)
    }
    private var volume: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
            TextField("Volume", value: percent, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 44).accessibilityLabel("Loop volume percentage")
            Text("%").font(.caption).foregroundStyle(.secondary)
            Slider(value: $model.volume, in: 0...1).frame(minWidth: 140, idealWidth: 180, maxWidth: 250).accessibilityLabel("Loop playback volume")
        }
    }
}
