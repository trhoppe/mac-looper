import SwiftUI
#if os(iOS)
import UIKit
#endif

struct DrummerPanel: View {
    @ObservedObject var drums: PopDrummerModel
    let output: AudioDevice?
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    private var percent: Binding<Double> {
        Binding(get: { (drums.volume * 100).rounded() }, set: { if $0.isFinite { drums.volume = min(100, max(0, $0)) / 100 } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            transport.padding(.top, 1)
            if drums.loading { ProgressView().controlSize(.small) }
            if let error = drums.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if !drums.ready { Button("Retry Drummer") { Task { await drums.retry() } }.disabled(drums.loading) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                TextField("Drum volume", value: percent, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).hoverHighlight().multilineTextAlignment(.trailing).frame(width: 44)
                    .accessibilityLabel("Drummer volume percentage")
                Text("%").font(.caption).foregroundStyle(.secondary)
                Slider(value: $drums.volume, in: 0...1).hoverHighlight().accessibilityLabel("Drummer volume")
            }
        }.padding(16).background(Color(red: 0.075, green: 0.085, blue: 0.10))

    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").foregroundStyle(accent)
                Text("Drummer").font(.callout.weight(.semibold))
            }
            Text("\(Int(drums.tempo)) BPM").font(.system(size: 18, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
        }.fixedSize()
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
