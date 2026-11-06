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
    @State private var measuredRailLooperMinimum = 360.0
    @State private var measuredRailWidth = 340.0
    #if os(macOS)
    @AppStorage("desktopLooperInRightRail") private var desktopLooperInRightRail = false
    #endif
    @AppStorage("showChords") private var showingChords = true
    @AppStorage("showLooper") private var showingLooper = true
    @AppStorage("showDrummer") private var showingDrummer = true
    @AppStorage("showPlayer") private var showingPlayer = true
    @AppStorage("audioPaneWidth") private var audioWidth = 340.0
    @AppStorage("jamFooterHeight") private var footerHeight = 230.0
    @AppStorage("rightRailPlayerHeight") private var railPlayerHeight = 280.0
    @AppStorage("rightRailLooperHeight") private var railLooperHeight = 380.0
    @AppStorage("compactPlayerDrummerHeight") private var compactRailHeight = 450.0
    @State private var drumOutput: AudioDevice?
    @State private var importing = false
    @State private var importKind = ImportKind.libraryFolder
    @State private var editingDraft: SongDraft?
    private var compactPlayerMinimumHeight: Double {
        280
    }
    private var railHasLooper: Bool {
        #if os(macOS)
        desktopLooperInRightRail && showingLooper
        #else
        false
        #endif
    }
    private var bottomLooperVisible: Bool { showingLooper && !railHasLooper }
    private var railVisible: Bool { showingPlayer || railHasLooper || showingDrummer }
    private var splitThickness: Double {
        #if os(macOS)
        8
        #else
        16
        #endif
    }
    private func railMinimumHeight(compact: Bool) -> Double {
        let count = [showingPlayer, railHasLooper, showingDrummer].filter { $0 }.count
        return (showingPlayer ? compactPlayerMinimumHeight : 0) +
        (railHasLooper ? measuredRailLooperMinimum : 0) +
        (showingDrummer ? (compact || railHasLooper ? 130 : 180) : 0) +
        Double(max(0, count - 1)) * splitThickness
    }
    private let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.files === rhs.files && lhs.library === rhs.library && lhs.remote === rhs.remote }
    private enum ImportKind { case libraryFolder, audioFolder }
    private var types: [UTType] { [.folder] }
    private var settingsContent: some View {
        AudioSettingsView(model: model, library: library, dismiss: { showingSettings = false },
                          chooseFolder: { beginImport(.libraryFolder) }, recoverDraft: { draft in
                              showingSettings = false; library.editing = true; editingDraft = draft
                          })
    }

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
                        #if os(macOS)
                        .anchorPreference(key: SettingsPopupAnchorKey.self, value: .bounds) { showingSettings ? $0 : nil }
                        #else
                        .popover(isPresented: $showingSettings, arrowEdge: .top) {
                            settingsContent
                                .frame(width: min(430, max(0, geo.size.width - 32)),
                                       height: max(0, geo.size.height * 0.9 - navigationHeight - 8))
                                .presentationCompactAdaptation(.popover)
                        }
                        #endif
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
            .overlayPreferenceValue(SettingsPopupAnchorKey.self) { anchor in
                if let anchor {
                    WindowSettingsPopup(anchor: anchor, close: { showingSettings = false }) { settingsContent }
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
        let workspaceVisible = showingChords || railVisible
        if workspaceVisible && bottomLooperVisible {
            ResizableSplit(axis: .vertical, side: .trailing, size: $footerHeight, defaultSize: 230,
                           minimumLeading: 200, minimumTrailing: measuredLooperMinimum,
                           label: "Resize chart and jam controls") {
                chartAndPlayer(windowWidth: width)
            } trailing: { looperPane }
        } else if workspaceVisible {
            chartAndPlayer(windowWidth: width)
        } else if bottomLooperVisible {
            looperPane
        } else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private func chartAndPlayer(windowWidth: Double) -> some View {
        let chordsVisible = showingChords, showsRail = railVisible, looperInRail = railHasLooper
        let compactMinimum = railMinimumHeight(compact: true)
        return GeometryReader { geo in
            if chordsVisible && showsRail {
                if windowWidth >= 1000 && geo.size.width >= 660 {
                    ResizableSplit(axis: .horizontal, side: .trailing, size: $audioWidth, defaultSize: 340,
                                   minimumLeading: 300, minimumTrailing: looperInRail ? 340 : 320, label: "Resize right rail") {
                        ChordChartView(song: library.selectedSong, edit: beginEditing)
                    } trailing: { rightRail(compact: false) }
                } else {
                    ResizableSplit(axis: .vertical, side: .trailing, size: $compactRailHeight, defaultSize: compactMinimum,
                                   minimumLeading: 140, minimumTrailing: compactMinimum, label: "Resize compact player and drummer") {
                        ChordChartView(song: library.selectedSong, edit: beginEditing)
                    } trailing: {
                        rightRail(compact: true)
                    }
                }
            } else if chordsVisible {
                ChordChartView(song: library.selectedSong, edit: beginEditing)
            } else if showsRail {
                rightRail(compact: windowWidth < 1000)
            }
        }
    }
    private func rightRail(compact: Bool) -> some View {
        // Capture values before the geometry closure so AppStorage visibility
        // changes invalidate its content even when the rail's size is unchanged.
        let playerVisible = showingPlayer, looperInRail = railHasLooper, drummerVisible = showingDrummer
        let compactDrummer = compact || looperInRail
        let count = [playerVisible, looperInRail, drummerVisible].filter { $0 }.count
        let minimum = railMinimumHeight(compact: compact)
        return GeometryReader { geo in
            if count > 1 && geo.size.height < minimum {
                // A short window can scroll the rail without squeezing out controls.
                ScrollView {
                    VStack(spacing: 0) {
                        if playerVisible {
                            AudioFileRail(model: files, accent: accent, compact: true)
                            Divider()
                        }
                        if drummerVisible {
                            DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput, compact: compactDrummer)
                                .frame(minHeight: compactDrummer ? 130 : 180)
                            if looperInRail { Divider() }
                        }
                        if looperInRail {
                            loopPane(compact: true).frame(height: measuredRailLooperMinimum)
                        }
                    }
                }
            } else if playerVisible && (looperInRail || drummerVisible) {
                ResizableSplit(axis: .vertical, side: .leading, size: $railPlayerHeight, defaultSize: compactPlayerMinimumHeight,
                               minimumLeading: compactPlayerMinimumHeight,
                               minimumTrailing: minimum - compactPlayerMinimumHeight - splitThickness,
                               label: drummerVisible ? "Resize Player and Drummer" : "Resize Player and Looper") {
                    ScrollView { AudioFileRail(model: files, accent: accent, compact: true) }
                } trailing: { lowerRail(hasLooper: looperInRail, hasDrummer: drummerVisible, compactDrummer: compactDrummer) }
            } else if playerVisible {
                ScrollView { AudioFileRail(model: files, accent: accent, compact: true) }
            } else {
                lowerRail(hasLooper: looperInRail, hasDrummer: drummerVisible, compactDrummer: compactDrummer)
            }
        }.background(Color(red: 0.075, green: 0.085, blue: 0.10))
            .onGeometryChange(for: Double.self) { $0.size.width } action: { measuredRailWidth = $0 }
    }
    @ViewBuilder private func lowerRail(hasLooper: Bool, hasDrummer: Bool, compactDrummer: Bool) -> some View {
        if hasLooper && hasDrummer {
            ResizableSplit(axis: .vertical, side: .trailing, size: $railLooperHeight, defaultSize: 380,
                           minimumLeading: compactDrummer ? 130 : 180, minimumTrailing: measuredRailLooperMinimum,
                           label: "Resize Drummer and Looper") {
                drummerPane(compact: compactDrummer)
            } trailing: { loopPane(compact: true) }
        } else if hasLooper {
            loopPane(compact: true)
        } else {
            drummerPane(compact: compactDrummer)
        }
    }
    private var looperPane: some View { loopPane(compact: false) }
    private func loopPane(compact: Bool) -> some View {
        GeometryReader { geo in
            ScrollView {
                LooperPanel(model: model, compact: compact, availableHeight: geo.size.height,
                            volumeWidth: geo.size.width >= 1000 && showingChords && railVisible ? max(180, measuredRailWidth - 32) : 260) {
                    if compact { measuredRailLooperMinimum = max(320, $0) }
                    else { measuredLooperMinimum = max(208, $0) }
                }
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
