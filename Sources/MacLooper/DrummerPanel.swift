import JamDesignKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct DrummerPanel: View {
    @ObservedObject var drums: PopDrummerModel
    let output: AudioDevice?
    var compact = false
    @State private var showingRhythms = false
    @State private var rhythmQuery = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        JamModuleTitle("Drummer", icon: "square.grid.2x2").padding(.trailing, 6)
                        playButton
                        rhythmMenu.frame(minWidth: 100, idealWidth: 150)
                        Spacer(minLength: 8)
                        VolumeControl(volume: $drums.volume, name: "Drummer")
                        editorControls
                    }
                    VStack(alignment: .leading, spacing: 12) { header; transportControls }
                }
            } else {
                header
                transportControls
            }
            if let error = drums.error {
                Text(error).font(.caption).foregroundStyle(JamDesign.armed).fixedSize(horizontal: false, vertical: true)
                if !drums.ready { Button("Retry Drummer") { Task { await drums.retry() } }.disabled(drums.loading) }
            }
        }.jamSurface(padding: compact ? 12 : 16)
            .task(id: output?.uid) { await drums.loadRhythms(output: output) }
    }
    private var header: some View {
        HStack {
            JamModuleTitle("Drummer", icon: "square.grid.2x2")
            Spacer(minLength: 4)
            VolumeControl(volume: $drums.volume, name: "Drummer")
        }
    }
    private var transportControls: some View {
        HStack(spacing: compact ? 6 : 12) {
            playButton
            rhythmMenu.frame(maxWidth: .infinity, alignment: .leading)
            editorControls
        }
    }
    private var editorControls: some View {
        HStack(spacing: 6) {
            editorButton
            if drums.loading || drums.selectingRhythm {
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Loading drummer")
            }
        }
    }
    private var rhythmMenu: some View {
        Button { drums.refreshRhythms(); showingRhythms.toggle(); rhythmQuery = "" } label: {
            HStack(spacing: 6) {
                Text(drums.selectedRhythmName ?? "Rhythm").lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
            }.font(.system(size: 13, weight: .medium))
                .foregroundStyle(JamDesign.text).padding(.horizontal, 10)
                .frame(height: JamDesign.target)
                .background(JamDesign.control, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(JamPlainButtonStyle()).fixedSize(horizontal: false, vertical: true)
            .disabled(drums.loading || drums.selectingRhythm || output == nil)
            .accessibilityLabel("Drummer rhythm").accessibilityValue(drums.selectedRhythmName ?? "No rhythm selected")
            .help("Choose a saved user rhythm")
            .anchorPreference(key: JamDropdownPopupKey.self, value: .bounds) { anchor in
                showingRhythms ? JamDropdownRequest(anchor: anchor, title: "Drummer rhythms", content: AnyView(rhythmBrowser),
                    close: { showingRhythms = false }, height: 380, opensBeside: true) : nil
            }
    }
    private var rhythmBrowser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("User rhythms").font(JamDesign.moduleTitleFont)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(JamDesign.secondary)
                    TextField("Search rhythms", text: $rhythmQuery).textFieldStyle(.plain)
                }.padding(8).background(JamDesign.control, in: RoundedRectangle(cornerRadius: 8))
            }.padding(14)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if drums.rhythms.isEmpty {
                            Text("Name saved rhythms “User - …” in Pop Drummer to include them here.")
                                .font(.caption).foregroundStyle(JamDesign.secondary).padding(10)
                        }
                        ForEach(drums.rhythms.filter { rhythmQuery.isEmpty || $0.displayName.localizedCaseInsensitiveContains(rhythmQuery) }) { rhythm in
                            Button {
                                showingRhythms = false
                                Task { await drums.selectRhythm(rhythm, output: output) }
                            } label: {
                                HStack {
                                    Text(rhythm.displayName).lineLimit(2)
                                    Spacer(minLength: 4)
                                    if drums.selectedRhythmID == rhythm.id { Image(systemName: "checkmark") }
                                }.font(.system(size: 14)).foregroundStyle(JamDesign.text)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(drums.selectedRhythmID == rhythm.id ? JamDesign.control : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(JamPlainButtonStyle()).id(rhythm.id)
                        }
                    }.padding(8)
                }.onAppear { if let id = drums.selectedRhythmID { scroll.scrollTo(id, anchor: .center) } }
            }
        }.background(JamDesign.card)
    }
    private var playButton: some View {
        Button { Task { await drums.toggle(output: output) } } label: {
            Image(systemName: drums.playing ? "stop.fill" : "play.fill")
        }.buttonStyle(JamIconStyle())
            .disabled(drums.loading || drums.selectingRhythm || output == nil)
            .accessibilityLabel(drums.playing ? "Stop drums" : "Play drums")
            .help(drums.playing ? "Stop drums" : "Play drums")
    }
    private var editorButton: some View {
        Button { Task { await drums.openEditor() } } label: {
            Image(systemName: "slider.horizontal.3")
        }.buttonStyle(JamIconStyle()).disabled(drums.loading || drums.selectingRhythm).accessibilityLabel("Open drummer editor").help("Open drummer editor")
    }

}
struct DrummerEditorPresentation: ViewModifier {
    @ObservedObject var drums: PopDrummerModel
    func body(content: Content) -> some View {
        #if os(iOS)
        content
        .sheet(isPresented: $drums.showingEditor, onDismiss: { drums.editorDidClose() }) {
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
