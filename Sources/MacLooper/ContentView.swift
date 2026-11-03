import SwiftUI
import UniformTypeIdentifiers
import JamCore
import Combine
import AM4RemoteKit

struct ContentView: View, Equatable {
    let model: LooperModel
    let readiness: AppReadinessModel
    let files: AudioFilePlayerModel
    @ObservedObject var remote: AM4RemoteSession
    @ObservedObject var library: SongLibraryModel
    @Environment(\.scenePhase) private var phase
    @State private var showingSettings = false
    @State private var showingSongs = false
    @AppStorage("showSongsSidebar") private var sidebar = true
    @AppStorage("showChords") private var showingChords = true
    @AppStorage("showLooper") private var showingLooper = true
    @AppStorage("showDrummer") private var showingDrummer = true
    @AppStorage("showPlayer") private var showingPlayer = true
    @AppStorage("songsPaneWidth") private var songsWidth = 240.0
    @AppStorage("audioPaneWidth") private var audioWidth = 340.0
    @AppStorage("jamFooterHeight") private var footerHeight = 230.0
    @AppStorage("drummerPaneWidth") private var drummerWidth = 340.0
    @AppStorage("drummerPaneHeight") private var drummerHeight = 150.0
    @AppStorage("compactPlayerHeight") private var compactPlayerHeight = 230.0
    @State private var drumOutput: AudioDevice?
    @State private var importing = false
    @State private var importKind = ImportKind.libraryFolder
    @State private var editingDraft: SongDraft?
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.files === rhs.files && lhs.library === rhs.library && lhs.remote === rhs.remote }
    private enum ImportKind { case libraryFolder, audioFolder }
    private var types: [UTType] { [.folder] }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                    panelButton("Songs", icon: "sidebar.left", visible: geo.size.width >= 1250 ? sidebar : showingSongs) {
                        if geo.size.width >= 1250 { sidebar.toggle() } else { showingSongs.toggle() }
                    }.popover(isPresented: $showingSongs) { SongBrowserView(library: library, onSelectSong: revealChords).frame(width: 310, height: 520) }
                    panelButton("Chords", icon: "text.alignleft", visible: showingChords) { showingChords.toggle() }
                    panelButton("Looper", icon: "arrow.triangle.2.circlepath", visible: showingLooper) { showingLooper.toggle() }
                    panelButton("Drummer", icon: "square.grid.2x2", visible: showingDrummer) { showingDrummer.toggle() }
                    panelButton("Player", icon: "music.note.list", visible: showingPlayer) { showingPlayer.toggle() }
                    panelButton("AM4 Remote", icon: "slider.horizontal.3", visible: remote.isPresented) { remote.present() }
                        }
                    }.frame(height: 32)
                    AppReadinessBadge(model: readiness)
                    Button { showingSettings.toggle() } label: { Image(systemName: "gearshape").font(.title3) }
                        .buttonStyle(.plain).accessibilityLabel("Settings")
                        .popover(isPresented: $showingSettings, arrowEdge: .top) {
                            AudioSettingsView(model: model, library: library, dismiss: { showingSettings = false },
                                              chooseFolder: { beginImport(.libraryFolder) }, recoverDraft: { draft in
                                                  showingSettings = false; library.editing = true; editingDraft = draft
                                              })
                        }
                }.padding(.horizontal, 18).padding(.vertical, 14)
                Divider()
                panes(width: geo.size.width)

            }
            .allowsHitTesting(editingDraft == nil && !remote.isPresented)
            .accessibilityHidden(editingDraft != nil || remote.isPresented)
            .overlay {
                if remote.isPresented {
                    AM4RemoteScreen(session: remote)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityAddTraits(.isModal)
                        .allowsHitTesting(true).accessibilityHidden(false)
                } else if let draft = editingDraft {
                    SongEditorView(draft: draft, library: library, close: endEditing) { draft in try await library.save(draft) }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityAddTraits(.isModal)
                        .allowsHitTesting(true).accessibilityHidden(false)
                }
            }
        }
        .background(Color(red: 0.065, green: 0.075, blue: 0.085)).tint(accent)
        .modifier(DrummerEditorPresentation(drums: AudioEngineHost.shared.drums))
        .fileImporter(isPresented: $importing, allowedContentTypes: types) { result in
            switch result {
            case .success(let url):
                switch importKind {
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
            if library.selectedSong != nil { revealChords() }
        }
        .onChange(of: library.selectedSong?.tempo) { _, tempo in
            if let tempo, tempo.isFinite, model.canEditTiming { model.bpm = min(240, max(30, tempo)) }
        }
        .onChange(of: phase) { _, value in
            if value == .active {
                model.refreshDevices(); Task { await library.refresh() }
                #if os(iOS)
                remote.setApplicationActive(true); model.handleAudioLifecycle(.foreground)
                #endif
            }
            #if os(iOS)
            if value == .background {
                remote.setApplicationActive(false); files.pauseForInterruption(); model.handleAudioLifecycle(.background)
            }
            #endif
        }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "json" { library.openLibrary(url) }
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
    @ViewBuilder private func panes(width: Double) -> some View {
        let songsVisible = width >= 1250 && sidebar
        let workspaceVisible = songsVisible || showingChords || showingPlayer
        if workspaceVisible && (showingLooper || showingDrummer) {
            ResizableSplit(axis: .vertical, side: .trailing, size: $footerHeight, defaultSize: 230,
                           minimumLeading: width < 1000 && showingChords && showingPlayer ? 380 : 200,
                           minimumTrailing: width < 1000 && showingLooper && showingDrummer ? 366 : 220,
                           label: "Resize chart and jam controls") {
                workspace(width: width, songsVisible: songsVisible)
            } trailing: { footer(width: width) }
        } else if workspaceVisible {
            workspace(width: width, songsVisible: songsVisible)
        } else if showingLooper || showingDrummer {
            footer(width: width)
        } else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    @ViewBuilder private func workspace(width: Double, songsVisible: Bool) -> some View {
        if songsVisible && (showingChords || showingPlayer) {
            ResizableSplit(axis: .horizontal, side: .leading, size: $songsWidth, defaultSize: 240,
                           minimumLeading: 220, minimumTrailing: showingChords && showingPlayer ? 660 : 320,
                           label: "Resize Songs sidebar") {
                SongBrowserView(library: library, onSelectSong: revealChords)
            } trailing: { chartAndPlayer(windowWidth: width) }
        } else if songsVisible {
            SongBrowserView(library: library, onSelectSong: revealChords)
        } else { chartAndPlayer(windowWidth: width) }
    }
    private func chartAndPlayer(windowWidth: Double) -> some View {
        GeometryReader { geo in
            if showingChords && showingPlayer {
                if windowWidth >= 1000 && geo.size.width >= 660 {
                    ResizableSplit(axis: .horizontal, side: .trailing, size: $audioWidth, defaultSize: 340,
                                   minimumLeading: 300, minimumTrailing: 320, label: "Resize audio files panel") {
                        ChordChartView(song: library.selectedSong, edit: beginEditing)
                    } trailing: { AudioFileRail(model: files, accent: accent, expanded: true) }
                } else {
                    ResizableSplit(axis: .vertical, side: .trailing, size: $compactPlayerHeight, defaultSize: 230,
                                   minimumLeading: 140, minimumTrailing: 230, label: "Resize compact player") {
                        ChordChartView(song: library.selectedSong, edit: beginEditing)
                    } trailing: {
                        ScrollView { AudioFileRail(model: files, accent: accent, compact: true) }
                    }
                }
            } else if showingChords {
                ChordChartView(song: library.selectedSong, edit: beginEditing)
            } else if showingPlayer {
                AudioFileRail(model: files, accent: accent, expanded: true)
            }
        }
    }
    @ViewBuilder private func footer(width: Double) -> some View {
        if showingLooper && showingDrummer {
            if width >= 1000 {
                ResizableSplit(axis: .horizontal, side: .trailing, size: $drummerWidth, defaultSize: 340,
                               minimumLeading: 480, minimumTrailing: 260, label: "Resize Looper and Drummer") {
                    looperPane
                } trailing: { drummerPane }
            } else {
                ResizableSplit(axis: .vertical, side: .trailing, size: $drummerHeight, defaultSize: 150,
                               minimumLeading: 220, minimumTrailing: 130, label: "Resize stacked Looper and Drummer") {
                    looperPane
                } trailing: { drummerPane }
            }
        } else if showingLooper { looperPane }
        else { drummerPane }
    }
    private var looperPane: some View {
        GeometryReader { geo in
            ScrollView {
                LooperPanel(model: model, waveformHeight: max(56, geo.size.height - 150))
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
            }
        }.background(Color(red: 0.075, green: 0.085, blue: 0.10))
    }
    private var drummerPane: some View {
        GeometryReader { geo in
            ScrollView {
                DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, idealHeight: geo.size.height, alignment: .topLeading)
            }
        }.background(Color(red: 0.075, green: 0.085, blue: 0.10))
    }
    private func endEditing() {
        editingDraft = nil; library.editing = false
        Task { await library.refresh() }
    }
    private func beginEditing() {
        guard let id = library.selectedSongID, let song = library.library?.songs.first(where: { $0.id == id }) else { return }
        library.editing = true; editingDraft = SongDraft(song: song)
    }
    private func revealChords() { showingChords = true; showingSongs = false }
    private func beginImport(_ kind: ImportKind) { showingSettings = false; importKind = kind; importing = true }
}
