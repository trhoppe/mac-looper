import SwiftUI
#if os(iOS)
import UIKit
#endif

struct DrummerPanel: View {
    @ObservedObject var drums: PopDrummerModel
    let timing: LooperModel
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
            VolumeControl(volume: $drums.volume, name: "Drummer")
                .padding(.top, tightVolumeSpacing ? 7 : 0)
            if tightVolumeSpacing { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, compact ? 12 : 16)
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
        TempoControl(model: timing, context: "Drummer").fixedSize()
    }
    private var transport: some View {
        HStack(spacing: 8) {
            Button { Task { await drums.toggle(output: output) } } label: {
                Image(systemName: drums.playing ? "stop.fill" : "play.fill").font(.system(size: 20)).frame(width: 36, height: 36)
            }
                .disabled(drums.loading || output == nil)
                .accessibilityLabel(drums.playing ? "Stop drums" : "Play drums")
                .help(drums.playing ? "Stop drums" : "Play drums")
            Button { Task { await drums.openEditor() } } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 20)).frame(width: 36, height: 36)
            }.disabled(drums.loading).accessibilityLabel("Open drummer editor").help("Open drummer editor")
        }.buttonStyle(JamPlainButtonStyle())
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
