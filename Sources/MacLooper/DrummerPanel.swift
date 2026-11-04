import SwiftUI
#if os(iOS)
import UIKit
#endif

struct DrummerPanel: View {
    @ObservedObject var drums: PopDrummerModel
    let output: AudioDevice?
    var compact = false
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    private var tightVolumeSpacing: Bool {
        #if os(macOS)
        compact
        #else
        false
        #endif
    }
    private var percent: Binding<Double> {
        Binding(get: { (drums.volume * 100).rounded() }, set: { if $0.isFinite { drums.volume = min(100, max(0, $0)) / 100 } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            if compact {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) { title; Spacer(minLength: 8); transport.fixedSize() }
                    tempo
                }
            } else {
                heading
                transport.padding(.top, 1)
            }
            if drums.loading { ProgressView().controlSize(.small) }
            if let error = drums.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if !drums.ready { Button("Retry Drummer") { Task { await drums.retry() } }.disabled(drums.loading) }
            }
            if !tightVolumeSpacing { Spacer(minLength: 0) }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                TextField("Drum volume", value: percent, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.plain).jamNumberField(width: 36, fontSize: 12).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Drummer volume percentage")
                Text("%").font(.caption).foregroundStyle(.secondary)
                Slider(value: $drums.volume, in: 0...1).hoverHighlight().accessibilityLabel("Drummer volume")
            }.padding(.top, tightVolumeSpacing ? 7 : 0)
            if tightVolumeSpacing { Spacer(minLength: 0) }
        }.padding(.horizontal, 16).padding(.vertical, compact ? 12 : 16)
            .background(Color(red: 0.075, green: 0.085, blue: 0.10))

    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 13) {
            title
            tempo
        }.fixedSize()
    }
    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2").foregroundStyle(accent)
            Text("Drummer").font(.callout.weight(.semibold))
        }.fixedSize()
    }
    private var tempo: some View {
        Text("\(Int(drums.tempo)) BPM").font(.system(size: 18, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
    }
    private var transport: some View {
        HStack(spacing: 8) {
            Button { Task { await drums.toggle(output: output) } } label: {
                Label(drums.playing ? "Stop" : "Play", systemImage: drums.playing ? "stop.fill" : "play.fill").frame(minWidth: 55)
            }.buttonStyle(JamButtonStyle(prominent: true)).tint(accent).foregroundStyle(.black)
                .disabled(drums.loading || output == nil)
                .accessibilityLabel(drums.playing ? "Stop drums" : "Play drums")
            Button { Task { await drums.openEditor() } } label: {
                Text("Open…").frame(minWidth: 55)
            }.buttonStyle(JamButtonStyle()).disabled(drums.loading).accessibilityLabel("Open drummer editor")
        }.controlSize(.large)
    }
}
struct DrummerEditorPresentation: ViewModifier {
    @ObservedObject var drums: PopDrummerModel
    func body(content: Content) -> some View {
        #if os(iOS)
        content
        .sheet(isPresented: $drums.showingEditor, onDismiss: { drums.saveState() }) {
            VStack(spacing: 0) {
                HStack { Text("Drummer").font(.headline); Spacer(); Button("Done") { drums.showingEditor = false } }.padding()
                if let editor = drums.editor { PluginEditorView(controller: editor) }
            }.presentationDragIndicator(.visible).presentationDetents([.large])
        }

        #else
        content
        #endif
    }
}
#if os(iOS)
private struct PluginEditorView: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
}
#endif
