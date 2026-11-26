import SwiftUI
import JamCore
import JamDesignKit

struct SavedLoopBrowser: View {
    @ObservedObject var model: LooperModel
    let close: () -> Void
    var onChoose: ((SavedLoopFile) -> Void)? = nil
    @State private var query = ""
    @Environment(\.scenePhase) private var phase

    private var matchingLoops: [SavedLoopFile] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? model.savedLoops : model.savedLoops.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        let files = matchingLoops
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("Saved loops").font(JamDesign.moduleTitleFont)
                    Spacer()
                    if model.readingSavedLoops { ProgressView().controlSize(.small).accessibilityLabel("Refreshing saved loops") }
                    Button { Task { await model.refreshSavedLoops() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(JamIconStyle()).disabled(model.readingSavedLoops)
                        .help("Refresh saved loops").accessibilityLabel("Refresh saved loops")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(JamDesign.secondary)
                    TextField("Search loops", text: $query).textFieldStyle(.plain)
                }.padding(8).background(JamDesign.control, in: RoundedRectangle(cornerRadius: 8))
            }.padding(14)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    if let error = model.savedLoopsError {
                        Text(error).font(.caption).foregroundStyle(JamDesign.armed).padding(10)
                    } else if model.savedLoops.isEmpty && !model.readingSavedLoops {
                        Text("No saved loops yet. Save a take to add it here.")
                            .font(.caption).foregroundStyle(JamDesign.secondary).padding(10)
                    }
                    if model.savedLoopsError == nil && !model.savedLoops.isEmpty && files.isEmpty {
                        Text("No matching loops. Try another name.")
                            .font(.caption).foregroundStyle(JamDesign.secondary).padding(10)
                    }
                    ForEach(files) { file in
                        Button {
                            if let onChoose { onChoose(file) }
                            else { Task { await model.openLoop(file.url) } }
                            close()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform").foregroundStyle(JamDesign.secondary)
                                Text(file.name).lineLimit(2)
                                Spacer(minLength: 4)
                                if file.url.standardizedFileURL == model.savedLoopURL?.standardizedFileURL { Image(systemName: "checkmark") }
                            }.font(.system(size: 14)).foregroundStyle(JamDesign.text)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .browserRowHighlight(selected: file.url.standardizedFileURL == model.savedLoopURL?.standardizedFileURL, background: .clear)
                        }.buttonStyle(JamPlainButtonStyle()).disabled(onChoose == nil && !model.canRecall)
                    }
                }.padding(8)
            }
            if onChoose == nil {
                Divider()
                Button {
                    close(); model.requestingLoopFile = true
                } label: {
                    Label("Open a loop file…", systemImage: "folder")
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.buttonStyle(JamPlainButtonStyle()).disabled(!model.canRecall)
                    .help("Open a loop saved elsewhere; Save copies it into the shared Loops folder")
            }
        }.background(JamDesign.card)
            .task(id: model.loopLibraryFolder) { await model.refreshSavedLoops() }
            .onChange(of: phase) { _, value in if value == .active { Task { await model.refreshSavedLoops() } } }
    }
}
