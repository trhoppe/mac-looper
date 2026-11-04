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
    @State private var navigationHeight = 60.0
    @State private var measuredLooperMinimum = 208.0
    @AppStorage("showChords") private var showingChords = true
    @AppStorage("showLooper") private var showingLooper = true
    @AppStorage("showDrummer") private var showingDrummer = true
    @AppStorage("showPlayer") private var showingPlayer = true
    @AppStorage("audioPaneWidth") private var audioWidth = 340.0
    @AppStorage("jamFooterHeight") private var footerHeight = 230.0
    @AppStorage("drummerPaneWidth") private var drummerWidth = 340.0
    @AppStorage("drummerPaneHeight") private var drummerHeight = 150.0
    @AppStorage("compactPlayerHeight") private var compactPlayerHeight = 230.0
    @State private var drumOutput: AudioDevice?
    @State private var importing = false
    @State private var importKind = ImportKind.libraryFolder
    @State private var editingDraft: SongDraft?
    private var compactPlayerMinimumHeight: Double {
        280
    }
    private var compactWorkspaceMinimumHeight: Double {
        compactPlayerMinimumHeight + 156
    }
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.files === rhs.files && lhs.library === rhs.library && lhs.remote === rhs.remote }
    private enum ImportKind { case libraryFolder, audioFolder }
    private var types: [UTType] { [.folder] }

    var body: some View {
        GeometryReader { geo in
            let compactHeader = geo.size.width < 1000
            VStack(spacing: 0) {
                HStack(spacing: compactHeader ? 8 : 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: compactHeader ? 8 : 12) {
                    panelButton("Songs", icon: "sidebar.left", visible: showingSongs, compact: compactHeader) {
                        showingSongs.toggle()
                    }
                    #if os(iOS)
                    .popover(isPresented: $showingSongs) { SongBrowserView(library: library, onSelectSong: revealChords, onAddSong: beginAdding)
                        .frame(width: 310, height: max(0, geo.size.height * 0.9 - navigationHeight - 8)) }
                    #endif
                    panelButton("Chords", icon: "text.alignleft", visible: showingChords, compact: compactHeader) { showingChords.toggle() }
                    panelButton("Looper", icon: "arrow.triangle.2.circlepath", visible: showingLooper, compact: compactHeader) { showingLooper.toggle() }
                    panelButton("Drummer", icon: "square.grid.2x2", visible: showingDrummer, compact: compactHeader) { showingDrummer.toggle() }
                    panelButton("Player", icon: "music.note.list", visible: showingPlayer, compact: compactHeader) { showingPlayer.toggle() }
                    panelButton("AM4 Remote", icon: "slider.horizontal.3", visible: remote.isPresented, compact: compactHeader) { remote.present() }
                        }
                    }.frame(height: 32)
                    AppReadinessBadge(model: readiness).fixedSize()
                    Button { showingSettings.toggle() } label: { Image(systemName: "gearshape").font(.title3).frame(width: 30, height: 30) }
                        .buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Settings")
                        .popover(isPresented: $showingSettings, arrowEdge: .top) {
                            AudioSettingsView(model: model, library: library, dismiss: { showingSettings = false },
                                              chooseFolder: { beginImport(.libraryFolder) }, recoverDraft: { draft in
                                                  showingSettings = false; library.editing = true; editingDraft = draft
                                              })
                        }
                }.padding(.horizontal, compactHeader ? 14 : 18).padding(.vertical, 14)
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { navigationHeight = $0 }
                Divider()
                panes(width: geo.size.width)
                    .environment(\.jamBrowserBounds, geo.frame(in: .global))

            }
            #if os(macOS)
            .overlayPreferenceValue(AudioBrowserPopupKey.self) { request in
                if let request { WindowAudioBrowserPopup(request: request, top: navigationHeight) }
            }
            .overlay(alignment: .topLeading) {
                if showingSongs {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle())
                            .onTapGesture { showingSongs = false }
                        JamPopupSurface(edge: .top, pointer: compactHeader ? 34 : 42) {
                            SongBrowserView(library: library, onSelectSong: revealChords, onAddSong: beginAdding)
                        }
                            .frame(width: min(310, max(0, geo.size.width - 28)),
                                   height: max(0, geo.size.height * 0.9 - navigationHeight + 2))
                            .padding(.leading, 14).padding(.top, navigationHeight - 2)
                        // The popup can open before its list owns keyboard focus.
                        Button("Close Songs") { showingSongs = false }
                            .keyboardShortcut(.cancelAction)
                            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                    }
                }
            }
            #endif
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
    private func panelButton(_ title: String, icon: String, visible: Bool, compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: compact ? 5 : 8) {
                Image(systemName: icon)
                Text(title)
            }.font(compact ? .callout : .body).foregroundStyle(visible ? accent : .secondary)
                .padding(.horizontal, compact ? 4 : 9).padding(.vertical, 6)
        }
            .buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Show or hide \(title.lowercased())")
            .accessibilityValue(visible ? "Shown" : "Hidden")
    }
    @ViewBuilder private func panes(width: Double) -> some View {
        let workspaceVisible = showingChords || showingPlayer
        if workspaceVisible && (showingLooper || showingDrummer) {
            ResizableSplit(axis: .vertical, side: .trailing, size: $footerHeight, defaultSize: 230,
                           minimumLeading: width < 1000 && showingChords && showingPlayer ? compactWorkspaceMinimumHeight : 200,
                           minimumTrailing: width < 1000 && showingLooper && showingDrummer ? measuredLooperMinimum + 146 : (showingLooper ? measuredLooperMinimum : 208),
                           label: "Resize chart and jam controls") {
                chartAndPlayer(windowWidth: width)
            } trailing: { footer(width: width) }
        } else if workspaceVisible {
            chartAndPlayer(windowWidth: width)
        } else if showingLooper || showingDrummer {
            footer(width: width)
        } else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private func chartAndPlayer(windowWidth: Double) -> some View {
        GeometryReader { geo in
            if showingChords && showingPlayer {
                if windowWidth >= 1000 && geo.size.width >= 660 {
                    ResizableSplit(axis: .horizontal, side: .trailing, size: $audioWidth, defaultSize: 340,
                                   minimumLeading: 300, minimumTrailing: 320, label: "Resize audio files panel") {
                        ChordChartView(song: library.selectedSong, edit: beginEditing)
                    } trailing: { AudioFileRail(model: files, accent: accent) }
                } else {
                    ResizableSplit(axis: .vertical, side: .trailing, size: $compactPlayerHeight, defaultSize: compactPlayerMinimumHeight,
                                   minimumLeading: 140, minimumTrailing: compactPlayerMinimumHeight, label: "Resize compact player") {
                        ChordChartView(song: library.selectedSong, edit: beginEditing)
                    } trailing: {
                        ScrollView { AudioFileRail(model: files, accent: accent, compact: true) }
                    }
                }
            } else if showingChords {
                ChordChartView(song: library.selectedSong, edit: beginEditing)
            } else if showingPlayer {
                AudioFileRail(model: files, accent: accent)
            }
        }
    }
    @ViewBuilder private func footer(width: Double) -> some View {
        if showingLooper && showingDrummer {
            if width >= 1000 {
                ResizableSplit(axis: .horizontal, side: .trailing, size: $drummerWidth, defaultSize: 340,
                               minimumLeading: 480, minimumTrailing: 260, label: "Resize Looper and Drummer") {
                    looperPane
                } trailing: { drummerPane(compact: false) }
            } else {
                ResizableSplit(axis: .vertical, side: .trailing, size: $drummerHeight, defaultSize: 150,
                               minimumLeading: measuredLooperMinimum, minimumTrailing: 130, label: "Resize stacked Looper and Drummer") {
                    looperPane
                } trailing: { drummerPane(compact: true) }
            }
        } else if showingLooper { looperPane }
        else { drummerPane(compact: width < 1000) }
    }
    private var looperPane: some View {
        GeometryReader { geo in
            ScrollView {
                LooperPanel(model: model, availableHeight: geo.size.height) { measuredLooperMinimum = max(208, $0) }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
            }
        }.background(Color(red: 0.075, green: 0.085, blue: 0.10))
    }
    private func drummerPane(compact: Bool) -> some View {
        GeometryReader { geo in
            ScrollView {
                DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput, compact: compact)
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
        library.editing = true; editingDraft = SongDraft(song: song, playlistIDs: library.library?.playlistIDs(containing: id))
    }
    private func beginAdding() {
        guard library.library != nil && !library.editing && !library.saving else { return }
        showingSongs = false; library.editing = true
        editingDraft = SongDraft(playlistIDs: library.playlistID.map { Set([$0]) } ?? [])
    }
    private func revealChords() { showingChords = true; showingSongs = false }
    private func beginImport(_ kind: ImportKind) { showingSettings = false; importKind = kind; importing = true }
}
