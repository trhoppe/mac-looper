import SwiftUI
import UniformTypeIdentifiers
import JamCore
import Combine

struct ContentView: View, Equatable {
    let model: LooperModel
    let readiness: AppReadinessModel
    let files: AudioFilePlayerModel
    @ObservedObject var library: SongLibraryModel
    @Environment(\.scenePhase) private var phase
    @State private var showingSettings = false
    @State private var showingSongs = false
    @AppStorage("showSongsSidebar") private var sidebar = true
    @AppStorage("showChords") private var showingChords = true
    @AppStorage("showLooper") private var showingLooper = true
    @AppStorage("showDrummer") private var showingDrummer = true
    @AppStorage("showPlayer") private var showingPlayer = true
    @State private var drumOutput: AudioDevice?
    @State private var importing = false
    @State private var importKind = ImportKind.source
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.files === rhs.files && lhs.library === rhs.library }
    private enum ImportKind { case source, libraryFolder, audioFolder }
    private var types: [UTType] { importKind == .source ? [.json] : [.folder] }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    panelButton("Songs", icon: "sidebar.left", visible: geo.size.width >= 1250 ? sidebar : showingSongs) {
                        if geo.size.width >= 1250 { sidebar.toggle() } else { showingSongs.toggle() }
                    }.popover(isPresented: $showingSongs) { SongBrowserView(library: library, onSelectSong: revealChords).frame(width: 310, height: 520) }
                    panelButton("Chords", icon: "text.alignleft", visible: showingChords) { showingChords.toggle() }
                    panelButton("Looper", icon: "arrow.triangle.2.circlepath", visible: showingLooper) { showingLooper.toggle() }
                    panelButton("Drummer", icon: "square.grid.2x2", visible: showingDrummer) { showingDrummer.toggle() }
                    panelButton("Player", icon: "music.note.list", visible: showingPlayer) { showingPlayer.toggle() }
                    Spacer(minLength: 8)
                    AppReadinessBadge(model: readiness)
                    Button { showingSettings.toggle() } label: { Image(systemName: "gearshape").font(.title3) }
                        .buttonStyle(.plain).accessibilityLabel("Settings")
                        .popover(isPresented: $showingSettings, arrowEdge: .top) {
                            AudioSettingsView(model: model, library: library, dismiss: { showingSettings = false },
                                              chooseSource: { beginImport(.source) }, chooseFolder: { beginImport(.libraryFolder) })
                        }
                }.padding(.horizontal, 18).padding(.vertical, 14)
                Divider()
                let songsVisible = geo.size.width >= 1250 && sidebar
                let workspaceVisible = songsVisible || showingChords || showingPlayer
                if workspaceVisible {
                    HStack(spacing: 0) {
                        if songsVisible {
                            SongBrowserView(library: library, onSelectSong: revealChords)
                                .frame(width: showingChords || showingPlayer ? 240 : nil)
                                .frame(maxWidth: showingChords || showingPlayer ? nil : .infinity)
                            if showingChords || showingPlayer { Divider() }
                        }
                        if showingChords {
                            VStack(spacing: 0) {
                                ChordChartView(song: library.selectedSong)
                                if showingPlayer && geo.size.width < 1000 {
                                    Divider()
                                    AudioFileRail(model: files, accent: accent, compact: true)
                                }
                            }
                        }
                        if showingPlayer && (!showingChords || geo.size.width >= 1000) {
                            if showingChords { Divider() }
                            AudioFileRail(model: files, accent: accent, expanded: !showingChords)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showingLooper || showingDrummer {
                    if workspaceVisible {
                        Divider()
                        footer(width: geo.size.width).fixedSize(horizontal: false, vertical: true)
                    } else {
                        footer(width: geo.size.width).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                } else if !workspaceVisible {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(red: 0.065, green: 0.075, blue: 0.085)).tint(accent)
        .modifier(DrummerEditorPresentation(drums: AudioEngineHost.shared.drums))
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
        .onAppear { files.setOutput(model.output); drumOutput = model.output }
        .onReceive(model.$outputUID.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in files.setOutput(model.output); drumOutput = model.output; model.routeDidChange() }
        .onReceive(model.$devices.dropFirst().receive(on: RunLoop.main)) { _ in files.setOutput(model.output); drumOutput = model.output }
        .onReceive(model.$inputUID.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in model.inputChannel = 0; model.routeDidChange() }
        .onReceive(model.$inputChannel.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in model.routeDidChange() }
        .onReceive(files.$requestingFolder.filter { $0 }.receive(on: RunLoop.main)) { _ in files.requestingFolder = false; beginImport(.audioFolder) }
        .onChange(of: library.selectedSongID) { _, _ in
            if let song = library.selectedSong {
                revealChords()
                if let tempo = song.tempo, tempo.isFinite, model.canEditTiming { model.bpm = min(240, max(30, tempo)) }
            }
        }
        .onChange(of: phase) { _, value in if value == .active { model.refreshDevices() } }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "json" { library.setSource(url) }
            else if AudioLibrary.isAudio(url) { files.selectFile(url) }
        }
    }
    private func panelButton(_ title: String, icon: String, visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).foregroundStyle(visible ? accent : .secondary)
                .padding(.horizontal, 9).padding(.vertical, 6).hoverHighlight()
        }
            .buttonStyle(.plain).accessibilityLabel("Show or hide \(title.lowercased())")
            .accessibilityValue(visible ? "Shown" : "Hidden")
    }
    @ViewBuilder private func footer(width: CGFloat) -> some View {
        if showingLooper && showingDrummer {
            if width >= 1000 {
                HStack(alignment: .top, spacing: 0) {
                    LooperPanel(model: model).frame(maxWidth: .infinity)
                    Divider()
                    DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput).frame(width: 340)
                }
            } else {
                VStack(spacing: 0) {
                    LooperPanel(model: model)
                    Divider()
                    DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput, compact: true)
                }
            }
        } else if showingLooper {
            LooperPanel(model: model).frame(maxWidth: .infinity)
        } else {
            DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput, compact: true).frame(maxWidth: .infinity)
        }
    }
    private func revealChords() { showingChords = true; showingSongs = false }
    private func beginImport(_ kind: ImportKind) { showingSettings = false; importKind = kind; importing = true }
}
