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
    @State private var showingMore = false
    @AppStorage("showChords") private var showingChords = true
    @AppStorage("showLooper") private var showingLooper = true
    @AppStorage("showDrummer") private var showingDrummer = true
    @AppStorage("showPlayer") private var showingPlayer = true
    @AppStorage("audioPaneWidth") private var audioWidth = 380.0
    @State private var drumOutput: AudioDevice?
    @State private var importing = false
    @State private var exportingLoop = false
    @State private var loopExport: LoopExport?
    @State private var confirmingLoopRecall = false
    @State private var loopFailure: String?
    @State private var importKind = ImportKind.libraryFolder
    @State private var editingDraft: SongDraft?
    private let accent = JamDesign.accent
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.files === rhs.files && lhs.library === rhs.library && lhs.remote === rhs.remote }
    private enum ImportKind { case libraryFolder, audioFolder, audioFile, loopFile }
    private var types: [UTType] { importKind == .loopFile ? [.jamLoop] : importKind == .audioFile ? [.audio] : [.folder] }
    private var settingsContent: some View {
        AudioSettingsView(model: model, library: library, dismiss: { showingSettings = false },
                          chooseFolder: { beginImport(.libraryFolder) }, recoverDraft: { draft in
                              showingSettings = false; library.editing = true; editingDraft = draft
                          })
    }

    var body: some View {
        GeometryReader { geo in
            let compactHeader = geo.size.width < 1180
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                    Button { showingSongs.toggle() } label: {
                        JamDropdownLabel("Songs", icon: "music.note.list", compact: compactHeader, active: showingSongs)
                    }.buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Show or hide songs").help("Songs")
                        .accessibilityValue(showingSongs ? "Shown" : "Hidden")
                        .anchorPreference(key: JamDropdownPopupKey.self, value: .bounds) { anchor in
                            showingSongs ? JamDropdownRequest(anchor: anchor, title: "Songs",
                                content: AnyView(SongBrowserView(library: library, onSelectSong: revealChords, onAddSong: beginAdding)),
                                close: { showingSongs = false }, width: 310, alignLeading: true) : nil
                        }
                    panelButton("Chart", icon: "text.alignleft", visible: showingChords, compact: compactHeader) { showingChords.toggle() }
                    panelButton("Player", icon: "waveform", visible: showingPlayer, compact: compactHeader) { showingPlayer.toggle() }
                    panelButton("Drummer", icon: "square.grid.2x2", visible: showingDrummer, compact: compactHeader) { showingDrummer.toggle() }
                    panelButton("Looper", icon: "arrow.triangle.2.circlepath", visible: showingLooper, compact: compactHeader) { showingLooper.toggle() }
                    Button { showingMore.toggle() } label: {
                        JamDropdownLabel("More", icon: compactHeader ? "ellipsis" : nil, compact: compactHeader, active: showingMore)
                    }.buttonStyle(JamPlainButtonStyle()).accessibilityLabel("More").help("More")
                        .anchorPreference(key: JamDropdownPopupKey.self, value: .bounds) { anchor in
                            showingMore ? JamDropdownRequest(anchor: anchor, title: "More", content: AnyView(moreContent),
                                close: { showingMore = false }, width: 230, height: JamDesign.target * 3 + 24, alignLeading: true) : nil
                        }
                        }
                    }.frame(height: JamDesign.target)
                    AppReadinessBadge(model: readiness, compact: compactHeader).fixedSize().padding(.trailing, 4)
                    TempoControl(model: model, context: "Global").fixedSize().padding(.trailing, 4)
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
                        .anchorPreference(key: JamDropdownPopupKey.self, value: .bounds) { anchor in
                            showingSettings ? JamDropdownRequest(anchor: anchor, title: "Settings", content: AnyView(settingsContent),
                                close: { showingSettings = false }, width: 430) : nil
                        }
                }.padding(.horizontal, compactHeader ? 14 : 18).padding(.vertical, 12)
                    .background(JamDesign.card)
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { navigationHeight = $0 }
                Divider()
                panes(width: geo.size.width, height: geo.size.height)

            }
            .overlayPreferenceValue(JamDropdownPopupKey.self) { request in
                if let request { JamDropdownPopup(request: request, top: navigationHeight) }
            }
            #if os(macOS)
            .overlayPreferenceValue(VolumePopupKey.self) { request in
                if let request { WindowVolumePopup(request: request) }
            }
            #endif
            .onChange(of: showingSongs) { _, showing in if showing { showingMore = false; showingSettings = false } }
            .onChange(of: showingMore) { _, showing in if showing { showingSongs = false; showingSettings = false } }
            .onChange(of: showingSettings) { _, showing in if showing { showingSongs = false; showingMore = false } }
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
                    SongEditorView(draft: draft, library: library, close: endEditing) { draft in try await library.save(draft) }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityAddTraits(.isModal)
                        .allowsHitTesting(true).accessibilityHidden(false)
                }
            }
        }
        .background(JamDesign.ground).foregroundStyle(JamDesign.text).tint(accent)
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
        .fileExporter(isPresented: $exportingLoop, document: loopExport?.document, contentType: .jamLoop, defaultFilename: loopExport?.name ?? "Loop") { result in
            if let loopExport { model.didSaveLoop(id: loopExport.id, result: result) }
            loopExport = nil
        }
        .alert(loopFailure == nil ? "Replace current loop?" : "Loop file", isPresented: Binding(
            get: { confirmingLoopRecall || loopFailure != nil },
            set: { if !$0 { confirmingLoopRecall = false; loopFailure = nil } }
        )) {
            if loopFailure != nil {
                Button("OK") { loopFailure = nil }
            } else {
                Button("Cancel", role: .cancel) { model.pendingRecall = nil }
                Button("Replace loop", role: .destructive) { Task { await model.confirmRecall() } }
            }
        } message: {
            Text(loopFailure ?? "Your current loop hasn’t been saved. Opening \(model.pendingRecall?.name ?? "this loop") will replace it.")
        }
        .onReceive(model.$requestingLoopFile.filter { $0 }.receive(on: RunLoop.main)) { _ in model.requestingLoopFile = false; beginImport(.loopFile) }
        .onReceive(model.$exportRequest.compactMap { $0 }.receive(on: RunLoop.main)) { request in
            model.exportRequest = nil; loopExport = request; exportingLoop = true
        }
        .onReceive(model.$pendingRecall.compactMap { $0 }.receive(on: RunLoop.main)) { _ in confirmingLoopRecall = true }
        .onReceive(model.$loopFileFailure.compactMap { $0 }.receive(on: RunLoop.main)) { failure in model.loopFileFailure = nil; loopFailure = failure }
        .onAppear { files.setOutput(model.output); drumOutput = model.output }
        .onReceive(model.$outputUID.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in files.setOutput(model.output); drumOutput = model.output; model.routeDidChange() }
        .onReceive(model.$devices.dropFirst().receive(on: RunLoop.main)) { _ in files.setOutput(model.output); drumOutput = model.output }
        .onReceive(model.$inputUID.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in model.inputChannel = 0; model.routeDidChange() }
        .onReceive(model.$inputChannel.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { _ in model.routeDidChange() }
        .onReceive(files.$requestingFolder.filter { $0 }.receive(on: RunLoop.main)) { _ in files.requestingFolder = false; beginImport(.audioFolder) }
        .onReceive(files.$requestingFile.filter { $0 }.receive(on: RunLoop.main)) { _ in files.requestingFile = false; beginImport(.audioFile) }
        .onReceive(files.$selected.compactMap { $0 }.receive(on: RunLoop.main)) { _ in showingPlayer = true }
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
        #if os(iOS)
        .onOpenURL { url in
            guard url.isFileURL else { return }
            if url.pathExtension.lowercased() == "jamloop" { Task { await model.openLoop(url) } }
            else if url.pathExtension.lowercased() == "json" { library.openLibrary(url) }
            else if AudioLibrary.isAudio(url) { files.selectFile(url, autoplay: true) }
        }
        #endif
    }
    private var moreContent: some View {
        VStack(spacing: 0) {
            moreItem("AM4 Remote", icon: "slider.horizontal.3") { remote.present() }
            moreItem("Chord Library", icon: "guitars") { showingChordLibrary = true }
            moreItem("Scales", icon: "music.note.list") { showingScaleLibrary = true }
        }.padding(8).frame(maxWidth: .infinity).background(JamDesign.card)
    }
    private func moreItem(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button { showingMore = false; action() } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: JamDesign.target, alignment: .leading).padding(.horizontal, 10)
        }.buttonStyle(JamPlainButtonStyle()).accessibilityLabel(title)
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
            .accessibilityLabel("Show or hide \(title == "Chart" ? "chords" : title.lowercased())")
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
                if showingDrummer { DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput, compact: true) }
                if showingPlayer || showingLooper {
                    EqualHeightCardRow(spacing: JamDesign.gap) {
                        if showingPlayer { AudioFileRail(model: files, accent: accent, compact: true, fillsHeight: true) }
                        if showingLooper { LooperPanel(model: model, fillsHeight: true) }
                    }
                }
                if !showingChords { Spacer(minLength: 0) }
            }.padding(12)
        } else if width >= 656 {
            horizontalWorkspace(song: song, includesLooper: true).padding(12)
        } else {
            VStack(spacing: JamDesign.gap) {
                if showingChords { ChordChartView(song: song, library: library, edit: beginEditing).frame(maxHeight: .infinity) }
                if showingPlayer || showingDrummer || showingLooper {
                    cardRail(includesLooper: true)
                        .frame(maxHeight: showingChords ? max(200, height * 0.52) : .infinity)
                }
            }.padding(12)
        }
        #endif
    }
    private func desktopWorkspace(song: LibrarySong?) -> some View {
        horizontalWorkspace(song: song, includesLooper: true).padding(16)
    }
    @ViewBuilder private func horizontalWorkspace(song: LibrarySong?, includesLooper: Bool) -> some View {
        let hasCards = showingPlayer || showingDrummer || (includesLooper && showingLooper)
        if showingChords && hasCards {
            ResizableSplit(axis: .horizontal, side: .trailing, size: $audioWidth, defaultSize: 380,
                           minimumLeading: 280, minimumTrailing: 328, label: "Resize right rail") {
                ChordChartView(song: song, library: library, edit: beginEditing)
            } trailing: { cardRail(includesLooper: includesLooper).padding(.leading, 8) }
        } else if showingChords {
            ChordChartView(song: song, library: library, edit: beginEditing)
        } else if hasCards {
            cardRail(includesLooper: includesLooper).frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
        } else { Color.clear }
    }
    private func cardRail(includesLooper: Bool) -> some View {
        ScrollView {
            VStack(spacing: JamDesign.gap) {
                if showingPlayer { playerCard }
                if showingDrummer { drummerCard }
                if includesLooper && showingLooper { looperCard }
            }.padding(.bottom, 4)
        }
    }
    private var playerCard: some View { AudioFileRail(model: files, accent: accent, compact: true) }
    private var drummerCard: some View {
        DrummerPanel(drums: AudioEngineHost.shared.drums, output: drumOutput,
                     compact: isIPad)
    }
    private var isIPad: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
    private var looperCard: some View { LooperPanel(model: model) }
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
