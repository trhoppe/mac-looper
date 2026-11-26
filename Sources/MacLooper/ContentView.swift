import JamDesignKit
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
    @State private var showingChordLibrary = false
    @State private var showingScaleLibrary = false
    @State private var navigationHeight = 60.0
    @State private var showingMix = false
    @AppStorage("showChords") private var showingChords = true
    @AppStorage("showJam") private var showingJam = true
    @AppStorage("audioPaneWidth") private var audioWidth = 380.0
    @State private var drumOutput: AudioDevice?
    @State private var importing = false
    @State private var namingLoop: LoopSaveRequest?
    @State private var loopSaveName = ""
    @State private var confirmingLoopRecall = false
    @State private var loopFailure: String?
    @State private var importKind = ImportKind.libraryFolder
    @State private var editingDraft: SongDraft?
    @State private var songSetupTask: Task<Void, Never>?
    @State private var loadingSongSetupID: String?
    #if os(iOS)
    private enum PhoneTab { case songs, chart, jam, tools }
    @State private var phoneTab = PhoneTab.songs
    @State private var settingsDismissAction: (() -> Void)?
    #endif
    private let accent = JamDesign.accent
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.files === rhs.files && lhs.library === rhs.library && lhs.remote === rhs.remote }
    private enum ImportKind { case libraryFolder, audioFolder, audioFile, loopFile }
    private var types: [UTType] { importKind == .loopFile ? [.jamLoop] : importKind == .audioFile ? [.audio] : [.folder] }
    private var settingsContent: some View {
        AudioSettingsView(model: model, library: library, dismiss: { showingSettings = false },
                          chooseFolder: { afterSettings { beginImport(.libraryFolder) } },
                          recoverDraft: { draft in
                              afterSettings { library.editing = true; editingDraft = draft }
                          })
    }

    private func afterSettings(_ action: @escaping () -> Void) {
        #if os(iOS)
        settingsDismissAction = action
        showingSettings = false
        #else
        showingSettings = false
        action()
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    phoneWorkspace
                } else {
                    wideWorkspace(width: geo.size.width, height: geo.size.height)
                }
                #else
                wideWorkspace(width: geo.size.width, height: geo.size.height)
                #endif
            }
            .overlayPreferenceValue(JamDropdownPopupKey.self) { request in
                if let request, !isPhone { JamDropdownPopup(request: request, top: navigationHeight) }
            }
            #if os(macOS)
            .overlayPreferenceValue(VolumePopupKey.self) { request in
                if let request { WindowVolumePopup(request: request) }
            }
            #endif
            .onChange(of: showingSongs) { _, showing in if showing { showingSettings = false } }
            .onChange(of: showingSettings) { _, showing in if showing { showingSongs = false } }
            .allowsHitTesting(editingDraft == nil && !remote.isPresented && !showingChordLibrary && !showingScaleLibrary)
            .accessibilityHidden(editingDraft != nil || remote.isPresented || showingChordLibrary || showingScaleLibrary)
            .overlay {
                if remote.isPresented {
                    AM4RemoteScreen(session: remote)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityAddTraits(.isModal)
                        .allowsHitTesting(true).accessibilityHidden(false)
                } else if showingChordLibrary {
                    ChordLibraryView { showingChordLibrary = false }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(true).accessibilityHidden(false)
                } else if showingScaleLibrary {
                    ScaleLibraryView { showingScaleLibrary = false }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(true).accessibilityHidden(false)
                } else if let draft = editingDraft {
                    SongEditorView(draft: draft, library: library, looper: model, close: endEditing) { draft in try await library.save(draft) }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityAddTraits(.isModal)
                        .allowsHitTesting(true).accessibilityHidden(false)
                }
            }
        }
        .background(JamDesign.ground).foregroundStyle(JamDesign.text).tint(accent)
        #if os(iOS)
        .sheet(isPresented: $showingSettings, onDismiss: {
            let action = settingsDismissAction
            settingsDismissAction = nil
            action?()
        }) { settingsContent }
        #endif
        .modifier(DrummerEditorPresentation(drums: AudioEngineHost.shared.drums))
        .fileImporter(isPresented: $importing, allowedContentTypes: types) { result in
            switch result {
            case .success(let url):
                switch importKind {
                case .libraryFolder: library.setFolder(url)
                case .audioFolder: files.openFolder(url)
                case .audioFile: files.selectFile(url, autoplay: true)
                case .loopFile: Task { await model.openLoop(url) }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    if importKind == .loopFile { loopFailure = error.localizedDescription }
                    else { files.error = error.localizedDescription }
                }
            }
        }
        .alert(namingLoop != nil ? "Save loop" : loopFailure == nil ? "Replace current loop?" : "Loop file", isPresented: Binding(
            get: { namingLoop != nil || confirmingLoopRecall || loopFailure != nil },
            set: { if !$0 { namingLoop = nil; confirmingLoopRecall = false; loopFailure = nil } }
        )) {
            if let request = namingLoop {
                TextField("Loop name", text: $loopSaveName)
                Button("Cancel", role: .cancel) { namingLoop = nil }
                Button("Save") { Task { await model.storeLoop(request, name: loopSaveName) } }
                    .disabled(loopSaveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if loopFailure != nil {
                Button("OK") { loopFailure = nil }
            } else {
                Button("Cancel", role: .cancel) { model.pendingRecall = nil }
                Button("Replace loop", role: .destructive) { Task { await model.confirmRecall() } }
            }
        } message: {
            Text(namingLoop != nil ? "Saved in your library’s Loops folder." : loopFailure ?? "Your current loop hasn’t been saved. Opening \(model.pendingRecall?.name ?? "this loop") will replace it.")
        }
        .onReceive(model.$requestingLoopFile.filter { $0 }.receive(on: RunLoop.main)) { _ in model.requestingLoopFile = false; beginImport(.loopFile) }
        .onReceive(model.$saveRequest.compactMap { $0 }.receive(on: RunLoop.main)) { request in
            model.saveRequest = nil; loopSaveName = request.name; namingLoop = request
        }
        .onReceive(model.$pendingRecall.receive(on: RunLoop.main)) { recall in
            confirmingLoopRecall = recall != nil
        }
        .onReceive(model.$loopFileFailure.compactMap { $0 }.receive(on: RunLoop.main)) { failure in model.loopFileFailure = nil; loopFailure = failure }
        .onAppear { files.setOutput(model.output); drumOutput = model.output }
        .onReceive(library.$folderURL.removeDuplicates().receive(on: RunLoop.main)) { model.configureLoopLibrary($0) }
        .onReceive(model.$outputUID.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in files.setOutput(model.output); drumOutput = model.output; model.routeDidChange() }
        .onReceive(model.$devices.dropFirst().receive(on: RunLoop.main)) { _ in files.setOutput(model.output); drumOutput = model.output }
        .onReceive(model.$inputUID.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in model.inputChannel = 0; model.routeDidChange() }
        .onReceive(model.$inputChannel.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in model.routeDidChange() }
        .onReceive(files.$requestingFolder.filter { $0 }.receive(on: RunLoop.main)) { _ in files.requestingFolder = false; beginImport(.audioFolder) }
        .onReceive(files.$requestingFile.filter { $0 }.receive(on: RunLoop.main)) { _ in files.requestingFile = false; beginImport(.audioFile) }
        .onChange(of: library.selectedSongID) { _, _ in
            if library.selectedSong != nil { revealChords() }
            loadSelectedSongSetup()
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
        #if os(iOS)
        .onOpenURL { url in
            guard url.isFileURL else { return }
            if url.pathExtension.lowercased() == "jamloop" { Task { await model.openLoop(url) } }
            else if url.pathExtension.lowercased() == "json" { library.openLibrary(url) }
            else if AudioLibrary.isAudio(url) { files.selectFile(url, autoplay: true) }
        }
        #endif
    }
    private func wideWorkspace(width: CGFloat, height: CGFloat) -> some View {
        let iconOnlyNavigation = isIPad ? height > width : width < 1180
        let compactHeader = iconOnlyNavigation || width < 1180
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button { showingSongs.toggle() } label: {
                            JamDropdownLabel("Songs", icon: "music.note.list", compact: compactHeader, active: showingSongs)
                        }.buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Show or hide songs").help("Songs")
                            .accessibilityValue(showingSongs ? "Shown" : "Hidden")
                            .anchorPreference(key: JamDropdownPopupKey.self, value: .bounds) { anchor in
                                showingSongs ? JamDropdownRequest(anchor: anchor, title: "Songs",
                                    content: AnyView(SongBrowserView(library: library, onSelectSong: chooseSong, onAddSong: beginAdding)),
                                    close: { showingSongs = false }, width: 310, alignLeading: true) : nil
                            }
                        panelButton("Chart", icon: "text.alignleft", visible: showingChords, compact: compactHeader) { showingChords.toggle() }
                        panelButton("Jam", icon: "waveform", visible: showingJam, compact: iconOnlyNavigation) { showingJam.toggle() }
                        toolButton("AM4", icon: "hifispeaker", compact: iconOnlyNavigation) { remote.present() }
                        toolButton("Chords", icon: "guitars", compact: iconOnlyNavigation) { showingChordLibrary = true }
                        toolButton("Scales", icon: "music.note", compact: iconOnlyNavigation) { showingScaleLibrary = true }
                    }
                }.frame(height: JamDesign.target)
                AppReadinessBadge(model: readiness, compact: compactHeader).fixedSize().padding(.trailing, 4)
                TempoControl(model: model, context: "Global", iconOnly: iconOnlyNavigation).fixedSize().padding(.trailing, 4)
                Button { showingMix.toggle() } label: {
                    Image(systemName: "slider.vertical.3")
                }.buttonStyle(JamIconStyle(active: showingMix)).accessibilityLabel("Mix").help("Mix Player, Drummer, and Looper volumes")
                    #if os(macOS)
                    .anchorPreference(key: VolumePopupKey.self, value: .bounds) { anchor in
                        showingMix ? VolumePopupRequest(anchor: anchor,
                            content: AnyView(JamMixView(looper: model, files: files, drums: AudioEngineHost.shared.drums)),
                            close: { showingMix = false }, width: 376, height: 320) : nil
                    }
                    #else
                    .popover(isPresented: $showingMix, arrowEdge: .top) {
                        JamMixView(looper: model, files: files, drums: AudioEngineHost.shared.drums)
                            .presentationCompactAdaptation(.popover)
                    }
                    #endif
                Button { showingSettings.toggle() } label: { JamDropdownLabel("Settings", icon: "gearshape", compact: true, active: showingSettings) }
                    .buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Settings").help("Settings")
                    #if os(macOS)
                    .anchorPreference(key: JamDropdownPopupKey.self, value: .bounds) { anchor in
                        showingSettings ? JamDropdownRequest(anchor: anchor, title: "Settings", content: AnyView(settingsContent),
                            close: { showingSettings = false }, width: 430) : nil
                    }
                    #endif
            }.padding(.horizontal, compactHeader ? 14 : 18).padding(.vertical, 12)
                .background(JamDesign.card)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { navigationHeight = $0 }
            Divider()
            panes(width: width, height: height)
        }
    }

    #if os(iOS)
    private var phoneWorkspace: some View {
        TabView(selection: $phoneTab) {
            VStack(spacing: 0) {
                SongBrowserView(library: library, onSelectSong: chooseSong, onAddSong: beginAdding)
                if library.library == nil && !library.syncing {
                    Button("Choose library folder…") { beginImport(.libraryFolder) }.padding(12)
                }
            }
                .tabItem { Label("Songs", systemImage: "music.note.list") }.tag(PhoneTab.songs)
            ChordChartView(song: library.selectedSong, library: library, edit: beginEditing)
                .tabItem { Label("Chart", systemImage: "text.alignleft") }.tag(PhoneTab.chart)
            ScrollView {
                VStack(spacing: 10) {
                    HStack {
                        AppReadinessBadge(model: readiness, compact: true)
                        TempoControl(model: model, context: "Global")
                        Spacer()
                        Button { showingMix = true } label: { Label("Mix", systemImage: "slider.vertical.3") }
                    }
                    playerCard
                    drummerCard
                    looperCard
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .overlayPreferenceValue(JamDropdownPopupKey.self) { request in
                if let request { JamDropdownPopup(request: request) }
            }
            .sheet(isPresented: $showingMix) {
                JamMixView(looper: model, files: files, drums: AudioEngineHost.shared.drums)
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .tabItem { Label("Jam", systemImage: "waveform") }.tag(PhoneTab.jam)
            List {
                Button { remote.present() } label: { Label("AM4", systemImage: "slider.horizontal.3") }
                Button { showingChordLibrary = true } label: { Label("Chords", systemImage: "guitars") }
                Button { showingScaleLibrary = true } label: { Label("Scales", systemImage: "music.note.list") }
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }.tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }.tag(PhoneTab.tools)
        }
    }
    #endif

    private func toolButton(_ title: String, icon: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button {
            showingSongs = false
            showingSettings = false
            showingMix = false
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 17))
                if !compact { Text(title).font(.system(size: 14, weight: .semibold)) }
            }
            .padding(.horizontal, compact ? 0 : 10)
            .frame(minWidth: JamDesign.target, minHeight: JamDesign.target)
        }.buttonStyle(JamPlainButtonStyle()).accessibilityLabel(title).help(title)
    }
    private func panelButton(_ title: String, icon: String, visible: Bool, compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 17, weight: .regular))
                if !compact { Text(title).font(.system(size: 14, weight: .semibold)) }
            }.foregroundStyle(visible ? JamDesign.accent : JamDesign.secondary)
                .padding(.horizontal, compact ? 0 : 11)
                .frame(minWidth: JamDesign.target, minHeight: JamDesign.target)
                .background(visible ? JamDesign.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(JamPlainButtonStyle()).help(title)
            .accessibilityLabel("Show or hide \(title.lowercased())")
            .accessibilityValue(visible ? "Shown" : "Hidden")
    }

    @ViewBuilder private func panes(width: Double, height: Double) -> some View {
        // Capture the song before layout closures so selections update immediately.
        let song = library.selectedSong
        #if os(macOS)
        desktopWorkspace(song: song)
        #else
        if height > width && width >= 656 {
            VStack(spacing: JamDesign.gap) {
                if showingChords { ChordChartView(song: song, library: library, edit: beginEditing).frame(maxHeight: .infinity) }
                if showingJam {
                    drummerCard
                    EqualHeightCardRow(spacing: JamDesign.gap) {
                        AudioFileRail(model: files, accent: accent, compact: true, fillsHeight: true)
                        LooperPanel(model: model, fillsHeight: true)
                    }
                }
                if !showingChords { Spacer(minLength: 0) }
            }.padding(12)
        } else if width >= 656 {
            horizontalWorkspace(song: song).padding(12)
        } else {
            VStack(spacing: JamDesign.gap) {
                if showingChords { ChordChartView(song: song, library: library, edit: beginEditing).frame(maxHeight: .infinity) }
                if showingJam {
                    cardRail
                        .frame(maxHeight: showingChords ? max(200, height * 0.52) : .infinity)
                }
            }.padding(12)
        }
        #endif
    }
    private func desktopWorkspace(song: LibrarySong?) -> some View {
        horizontalWorkspace(song: song).padding(16)
    }
    @ViewBuilder private func horizontalWorkspace(song: LibrarySong?) -> some View {
        if showingChords && showingJam {
            ResizableSplit(axis: .horizontal, side: .trailing, size: $audioWidth, defaultSize: 380,
                           minimumLeading: 280, minimumTrailing: 328, label: "Resize right rail") {
                ChordChartView(song: song, library: library, edit: beginEditing)
            } trailing: { cardRail.padding(.leading, 8) }
        } else if showingChords {
            ChordChartView(song: song, library: library, edit: beginEditing)
        } else if showingJam {
            cardRail.frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
        } else { Color.clear }
    }
    private var cardRail: some View {
        ScrollView {
            VStack(spacing: JamDesign.gap) {
                playerCard
                drummerCard
                looperCard
            }.padding(.bottom, 4)
        }
    }
    private var playerCard: some View { AudioFileRail(model: files, accent: accent, compact: true) }
    private var drummerCard: some View {
        DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput,
                     compact: isIPad)
    }
    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
    private var isIPad: Bool {
        #if os(iOS)
        !isPhone
        #else
        false
        #endif
    }
    private var looperCard: some View { LooperPanel(model: model, compact: isPhone) }
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
    private func chooseSong() {
        revealChords()
        loadSelectedSongSetup()
    }
    private func loadSelectedSongSetup() {
        let song = library.selectedSong
        let songID = song?.id
        guard songSetupTask == nil || loadingSongSetupID != songID else { return }
        if let pending = model.pendingRecall?.songID, pending != songID {
            model.pendingRecall = nil
        }
        let previous = songSetupTask
        previous?.cancel()
        loadingSongSetupID = songID
        let loop = song?.savedLoopName.flatMap { LibraryFiles.songLoopURL(named: $0, in: library.folderURL) }
        let backing = songID.flatMap { library.backingURL(songID: $0) }
        guard previous != nil || loop != nil || backing != nil else { return }
        songSetupTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            async let track: Void = loadSongBacking(backing)
            if let loop { await model.openLoop(loop, forSong: songID) }
            await track
            if !Task.isCancelled { songSetupTask = nil }
        }
    }
    private func loadSongBacking(_ url: URL?) async {
        guard let url else { return }
        do {
            try await library.prepareSongBacking(url)
            try Task.checkCancellation()
            files.selectSongBacking(url)
        } catch is CancellationError {
        } catch { if !Task.isCancelled { files.error = "Couldn’t load the song’s backing track: " + error.localizedDescription } }
    }
    private func revealChords() {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { phoneTab = .chart; return }
        #endif
        showingChords = true; showingSongs = false
    }
    private func beginImport(_ kind: ImportKind) { showingSettings = false; importKind = kind; importing = true }
}

/// Match sibling card heights to the taller content, without a stored fixed size.
private struct EqualHeightCardRow: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        let gap = spacing * max(0, count - 1)
        let idealWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = proposal.width ?? (idealWidth * count + gap)
        let cardWidth = max(0, (width - gap) / count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = max(0, (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}
