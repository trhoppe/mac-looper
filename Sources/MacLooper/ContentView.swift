import SwiftUI
import LooperCore

struct ContentView: View {
    @ObservedObject var model: LooperModel
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    private var recording: Bool { model.state == TL_RECORDING }
    private var boundedBPM: Binding<Double> {
        Binding(get: { model.bpm }, set: { if $0.isFinite { model.bpm = min(240, max(30, $0)) } })
    }
    private var boundedThreshold: Binding<Double> {
        Binding(get: { model.thresholdDB }, set: { if $0.isFinite { model.thresholdDB = min(0, max(-72, $0)) } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac Looper").font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("A few bars. Something to play over.").foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.running ? accent : Color.secondary).frame(width: 7, height: 7)
                Text(model.running ? "\(Int(model.sampleRate / 1000)) kHz" : "Audio off")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            routing
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TEMPO").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("BPM", value: boundedBPM, format: .number.precision(.fractionLength(0)))
                            .font(.system(size: 32, weight: .medium, design: .rounded)).textFieldStyle(.plain)
                            .frame(width: 70).accessibilityLabel("Tempo in beats per minute")
                        Text("BPM").foregroundStyle(.secondary)
                        Stepper("Tempo", value: boundedBPM, in: 30...240, step: 1).labelsHidden()
                    }
                }.disabled(!model.canEditTiming)
                VStack(alignment: .leading, spacing: 10) {
                    Text("LOOP LENGTH").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Picker("Bars", selection: $model.bars) {
                        Text("2 bars").tag(2); Text("4 bars").tag(4); Text("8 bars").tag(8)
                    }.pickerStyle(.segmented).frame(width: 250).disabled(!model.canEditTiming)
                    Text(String(format: "4/4 · %.2f seconds", model.seconds)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            threshold
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle().fill(recording ? .red : model.busy ? .orange : accent).frame(width: 8, height: 8)
                    Text(model.status).font(.headline)
                    Spacer()
                    if model.busy || model.hasLoop {
                        Text(recording ? "BAR \(min(model.bars, Int(model.progress * Double(model.bars)) + 1)) / \(model.bars)" : "\(model.bars) BARS")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                WaveformView(values: model.waveform, progress: model.progress, bars: model.bars,
                             active: model.hasLoop || recording, recording: recording, accent: accent)
                    .frame(height: 128)
                    .accessibilityLabel(recording ? "Recording waveform" : "Loop waveform")
                Text(model.detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 12) {
                Button { Task { await model.arm() } } label: {
                    Label("Arm", systemImage: "record.circle").frame(width: 100, height: 30)
                }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                    .disabled(!model.canEditTiming || model.input == nil || model.output == nil)
                    .help("Wait for your first strum, then record the selected number of bars. R")
                Button { model.playStop() } label: {
                    Label(model.state == TL_PLAYING || model.busy ? "Stop" : "Play",
                          systemImage: model.state == TL_PLAYING || model.busy ? "stop.fill" : "play.fill")
                        .frame(width: 94, height: 30)
                }.disabled(!model.hasLoop && !model.busy).help("Space. Stop during recording cancels the take.")
                Button { model.clear() } label: {
                    Label("Clear", systemImage: "trash").frame(width: 75, height: 30)
                }.disabled(!model.running || model.state == TL_EMPTY).help("Delete the loop and unlock tempo and length. Delete")
                Spacer()
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1).frame(width: 100).accessibilityLabel("Loop playback volume")
            }.buttonStyle(.bordered).controlSize(.large)
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text("Live guitar stays on the AM4. Only the loop plays here.")
                Spacer()
                Text("R  Arm   ·   Space  Play/Stop").font(.caption)
            }.font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28).frame(width: 720)
        .background(Color(red: 0.065, green: 0.075, blue: 0.085))
        .tint(accent)
        .onChange(of: model.inputUID) { _, _ in model.inputChannel = 0 }
    }
    private var routing: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                Picker("Input", selection: $model.inputUID) {
                    if model.input == nil { Text("Choose input…").tag(model.inputUID) }
                    ForEach(model.inputs) { Text($0.name).tag($0.uid) }
                }
                Picker("Output", selection: $model.outputUID) {
                    if model.output == nil { Text("Choose output…").tag(model.outputUID) }
                    ForEach(model.outputs) { Text($0.name).tag($0.uid) }
                }
            }.disabled(model.running || model.starting)
            HStack {
                Picker("Capture", selection: $model.inputChannel) {
                    ForEach(Array(stride(from: 0, to: max(1, model.input?.inputs ?? 2), by: 2)), id: \.self) { ch in
                        Text((model.input?.inputs ?? 2) > ch + 1 ? "Inputs \(ch + 1)–\(ch + 2)" : "Input \(ch + 1)").tag(ch)
                    }
                }.frame(width: 200).disabled(model.running || model.starting)
                Text("Playback: outputs 1–2").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.starting ? "Connecting…" : model.running ? "Stop Audio" : "Start Audio") {
                    if model.running { model.stopAudio() } else { Task { await model.startAudio() } }
                }.disabled(model.starting || model.input == nil || model.output == nil)
                    .help("Start Audio enables the input meter. Stop Audio clears the loop and releases the devices.")
            }
        }.font(.callout).padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private var threshold: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("STRUM THRESHOLD").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                TextField("Threshold", value: boundedThreshold, format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 58)
                    .accessibilityLabel("Strum threshold in decibels")
                Text("dB").font(.callout).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(accent.opacity(0.65)).frame(width: max(0, geo.size.width * min(1, max(0, (model.meterDB + 72) / 72))))
                    Rectangle().fill(.orange).frame(width: 2, height: 14)
                        .offset(x: min(geo.size.width - 2, max(0, geo.size.width * (model.thresholdDB + 72) / 72)))
                }
            }.frame(height: 8).accessibilityLabel("Input level \(Int(model.meterDB)) decibels")
            Slider(value: boundedThreshold, in: -72...0, step: 1).accessibilityLabel("Strum threshold")
            HStack {
                Text("Quiet"); Spacer()
                Text(model.running ? "Input \(Int(model.meterDB)) dB" : "Start audio to see input level").monospacedDigit()
                Spacer(); Text("Loud")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct WaveformView: View {
    let values: [Float]
    let progress: Double
    let bars: Int
    let active: Bool
    let recording: Bool
    let accent: Color
    var body: some View {
        Canvas { context, size in
            for bar in 0...bars {
                let x = size.width * Double(bar) / Double(bars)
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: 1)
            }
            let middle = size.height / 2
            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: middle)); baseline.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(baseline, with: .color(.white.opacity(0.1)), lineWidth: 1)
            for (i, value) in values.enumerated() where value > 0 {
                let x = size.width * (Double(i) + 0.5) / Double(values.count)
                let h = max(1, min(1, Double(value)) * middle * 0.94)
                var line = Path(); line.move(to: CGPoint(x: x, y: middle - h)); line.addLine(to: CGPoint(x: x, y: middle + h))
                context.stroke(line, with: .color(recording ? .red.opacity(0.85) : accent.opacity(0.8)), lineWidth: 2)
            }
            if active {
                let x = size.width * min(1, max(0, progress))
                var head = Path(); head.move(to: CGPoint(x: x, y: 0)); head.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(head, with: .color(recording ? .red : .white.opacity(0.85)), lineWidth: 1.5)
            }
        }
        .overlay {
            if !active && !values.contains(where: { $0 > 0 }) {
                Text("Your next idea goes here").font(.callout).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).background(Color(red: 0.09, green: 0.10, blue: 0.11))
            }
        }
    }
}
