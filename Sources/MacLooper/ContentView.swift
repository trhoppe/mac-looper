import SwiftUI
import UniformTypeIdentifiers
import JamCore

struct ContentView: View {
    @ObservedObject var model: LooperModel
    @ObservedObject var files: AudioFilePlayerModel
    @ObservedObject var library: SongLibraryModel
    @Environment(\.scenePhase) private var phase
    @State private var showingSettings = false
    @State private var showingSongs = false
    @State private var sidebar = true
    @State private var importing = false
    @State private var importKind = ImportKind.source
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    private enum ImportKind { case source, libraryFolder, audioFolder }
    private var types: [UTType] { importKind == .source ? [.json] : [.folder] }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        if geo.size.width >= 1250 { sidebar.toggle() } else { showingSongs.toggle() }
                    } label: { Label("Songs", systemImage: "sidebar.left") }
                        .buttonStyle(.plain).popover(isPresented: $showingSongs) { SongBrowserView(library: library).frame(width: 310, height: 520) }
                    Text("Mac Looper").font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(audioSummary)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { showingSettings.toggle() } label: { Image(systemName: "gearshape").font(.title3) }
                        .buttonStyle(.plain).accessibilityLabel("Settings")
                        .popover(isPresented: $showingSettings, arrowEdge: .top) { settings }
                }.padding(.horizontal, 18).padding(.vertical, 14)
                Divider()
                HStack(spacing: 0) {
                    if geo.size.width >= 1250 && sidebar {
                        SongBrowserView(library: library).frame(width: 218)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        ChordChartView(song: library.selectedSong)
                        if geo.size.width < 1000 {
                            Divider()
                            AudioFileRail(model: files, accent: accent, compact: true)
                        }
                    }
                    if geo.size.width >= 1000 {
                        Divider()
                        AudioFileRail(model: files, accent: accent)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                LooperPanel(model: model)
            }
        }
        .background(Color(red: 0.065, green: 0.075, blue: 0.085)).tint(accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: types) { result in
            switch result {
            case .success(let url):
                switch importKind {
                case .source: library.setSource(url)
                case .libraryFolder: library.setFolder(url)
                case .audioFolder: files.openFolder(url)
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { files.error = error.localizedDescription }
            }
        }
        .onAppear { files.setOutput(model.output) }
        .onChange(of: model.outputUID) { _, _ in files.setOutput(model.output); model.routeDidChange() }
        .onChange(of: model.devices) { _, _ in files.setOutput(model.output) }
        .onChange(of: model.inputUID) { _, _ in model.inputChannel = 0; model.routeDidChange() }
        .onChange(of: model.inputChannel) { _, _ in model.routeDidChange() }
        .onChange(of: files.requestingFolder) { _, requested in if requested { files.requestingFolder = false; beginImport(.audioFolder) } }
        .onChange(of: library.selectedSongID) { _, _ in
            showingSongs = false
            if let song = library.selectedSong {
                if let tempo = song.tempo, tempo.isFinite, model.canEditTiming { model.bpm = min(240, max(30, tempo)) }
            }
        }
        .onChange(of: phase) { _, value in if value == .active { model.refreshDevices() } }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "json" { library.setSource(url) }
            else if AudioLibrary.isAudio(url) { files.selectFile(url) }
        }
    }
    private func beginImport(_ kind: ImportKind) { showingSettings = false; importKind = kind; importing = true }
    private var audioSummary: String {
        if model.running { return "\(Int(model.sampleRate / 1000)) kHz · \(model.audioCallbackFrames) samples" }
        #if os(macOS)
        return "Audio off · 32 samples"
        #else
        return "Audio off"
        #endif
    }
    private var bufferSummary: String {
        #if os(macOS)
        return "32 samples"
        #else
        return model.running ? "\(model.audioCallbackFrames) samples" : "Requests 32 samples · iPadOS chooses buffer"
        #endif
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button { showingSettings = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                Text("Audio").font(.subheadline.weight(.semibold))
                VStack(spacing: 12) {
                    Picker("Input", selection: $model.inputUID) {
                        if model.input == nil { Text("Choose input…").tag(model.inputUID) }
                        ForEach(model.inputs) { Text($0.name).tag($0.uid) }
                    }
                    Picker("Output", selection: $model.outputUID) {
                        if model.output == nil { Text("Choose output…").tag(model.outputUID) }
                        ForEach(model.outputs) { Text($0.name).tag($0.uid) }
                    }
                    Picker("Capture", selection: $model.inputChannel) {
                        ForEach(Array(stride(from: 0, to: max(1, model.input?.inputs ?? 2), by: 2)), id: \.self) { ch in
                            Text((model.input?.inputs ?? 2) > ch + 1 ? "Inputs \(ch + 1)–\(ch + 2)" : "Input \(ch + 1)").tag(ch)
                        }
                    }
                }.disabled(model.starting || model.hasLoop || model.busy)
                Text(bufferSummary + " · outputs 1–2 · AM4 live monitoring").font(.caption).foregroundStyle(.secondary)
                Text(model.starting ? "Connecting audio…" : model.running ? "Audio connected automatically" : "Waiting for an audio interface")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.running && !model.starting {
                    Button("Retry Connection") { Task { await model.startAudio() } }
                        .disabled(model.input == nil || model.output == nil)
                }
                Divider()
                Text("Chord Library").font(.subheadline.weight(.semibold))
                Text(library.status).font(.caption).foregroundStyle(.secondary)
                if let source = library.sourceURL { Text("Source: \(source.lastPathComponent)").font(.caption).lineLimit(1) }
                Text("Mac Looper folder: \(library.folderURL.lastPathComponent)").font(.caption).lineLimit(2)
                Button("Choose JustChords library…") { beginImport(.source) }
                Button("Choose Mac Looper iCloud folder…") { beginImport(.libraryFolder) }
                Text("The source library stays read-only. Mac Looper keeps an exact-format copy in its own folder and syncs from JustChords only at app launch.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = library.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        }.frame(width: 430, height: 540).tint(accent)
    }
}
