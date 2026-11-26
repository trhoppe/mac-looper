import JamDesignKit
import SwiftUI
import JamCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct SongEditorView: View {
    @StateObject private var editor: SongEditorModel
    private var draft: SongDraft { editor.draft }
    @ObservedObject private var library: SongLibraryModel
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmingDiscard = false
    @State private var exporting = false
    @State private var showingDetails = false
    @State private var showingLoops = false
    @State private var importingBacking = false
    @State private var backingError: String?
    private let looper: LooperModel
    private var phone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
    let close: () -> Void
    let save: (SongDraft) async throws -> Void
    init(draft: SongDraft, library: SongLibraryModel, looper: LooperModel, close: @escaping () -> Void, save: @escaping (SongDraft) async throws -> Void) {
        self.library = library; self.looper = looper
        _editor = StateObject(wrappedValue: SongEditorModel(draft: draft, library: library)); self.close = close; self.save = save
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.isNew ? "New song" : "Edit song").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { exporting = true } label: {
                    if phone { Image(systemName: "square.and.arrow.up") } else { Text("Export ChordPro…") }
                }.accessibilityLabel("Export ChordPro").disabled(saving)
                Button("Cancel") {
                    if draft.hasChanges { confirmingDiscard = true } else { close() }
                }.disabled(saving).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving = true; saveError = nil
                    Task {
                        do { try await save(draft); try await editor.clearRecovery(); close() }
                        catch { saveError = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(JamButtonStyle(prominent: true)).keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || !draft.hasChanges || draft.validationError != nil)
            }.padding(18).background(JamDesign.card)
            if phone {
                Button("Song details") { showingDetails = true }.disabled(saving).padding(8)
                    .sheet(isPresented: $showingDetails) {
                        backingPicker {
                            NavigationStack {
                                Form {
                                    field("Song name", text: $editor.draft.title, prompt: "Song name")
                                    field("Artist", text: $editor.draft.artist, prompt: "Artist name")
                                    playlistField
                                    metadataFields
                                    jamSetup
                                }
                                .navigationDestination(isPresented: $showingLoops) {
                                    savedLoopPicker.navigationTitle("Choose Saved Loop")
                                }
                                .navigationTitle("Song details")
                            #if os(iOS)
                                .navigationBarTitleDisplayMode(.inline)
                            #endif
                                .toolbar {
                                    Button("Done") { showingDetails = false }
                                }
                            }
                        }
                    }
            } else {
                backingPicker {
                    VStack(spacing: 12) {
                        HStack(spacing: 14) {
                            field("Song name", text: $editor.draft.title, prompt: "Song name")
                            field("Artist", text: $editor.draft.artist, prompt: "Artist name")
                            playlistField.frame(minWidth: 140, maxWidth: 260)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 5), spacing: 12) {
                            metadataFields
                        }
                        Divider()
                        jamSetup
                    }.padding(.horizontal, 18).padding(.bottom, 14).disabled(saving)
                    #if os(iOS)
                    .sheet(isPresented: $showingLoops) { savedLoopPicker }
                    #endif
                }
            }
            Divider()
            HStack {
                Text("ChordPro").font(.subheadline.weight(.semibold))
                Spacer()
                Text(phone ? "Use [C] before a word." : "Details above edit the ChordPro header. Use [C] before a word.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 10)
            ChordProTextEditor(text: $editor.draft.chordPro).disabled(saving).frame(maxWidth: .infinity, maxHeight: .infinity)
            if editor.recovered { Text("Recovered unsaved edits. Review them, then Save or Cancel.").font(.caption).foregroundStyle(.secondary).padding(8) }
            if let message = saveError ?? editor.recoveryError ?? draft.validationError {
                Text(message).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .disabled(editor.recovering)
        .task { await editor.restore() }
        .background(JamDesign.ground)
        #if os(macOS)
        .sheet(isPresented: $showingLoops) { savedLoopPicker }
        #endif
        .fileExporter(isPresented: $exporting, document: ChordProExport(text: draft.chordPro), contentType: .plainText,
                      defaultFilename: String(draft.title.map { $0 == "/" || $0 == ":" ? "-" : $0 }) + ".cho") { result in
            if case .failure(let error) = result { saveError = error.localizedDescription }
        }
        .confirmationDialog("Keep these unsaved edits?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Keep draft and close") {
                Task { do { try await editor.keepForLater(); close() } catch { saveError = error.localizedDescription } }
            }
            Button("Discard changes", role: .destructive) {
                Task { do { try await editor.clearRecovery(); close() } catch { saveError = error.localizedDescription } }
            }
            Button("Keep editing", role: .cancel) { }
        }

    }
    private var jamSetup: some View {
        SongJamSetupFields(draft: $editor.draft, library: library, looper: looper, backingError: $backingError,
                           chooseLoop: { showingLoops = true }, chooseBacking: chooseBackingFile)
    }

    private var savedLoopPicker: some View {
        VStack(spacing: 0) {
            SavedLoopBrowser(model: looper, close: { showingLoops = false }, onChoose: { file in
                editor.draft.savedLoopName = file.url.lastPathComponent
            })
            Button("Done") { showingLoops = false }.padding()
        }
        .frame(minWidth: 300, idealWidth: 420, minHeight: 320, idealHeight: 480)
        .background(JamDesign.card)
    }

    private func chooseBackingFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose a backing track"
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { setBackingFile(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
        #else
        importingBacking = true
        #endif
    }

    private func backingPicker<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        content()
        #else
        content()
            .fileImporter(isPresented: $importingBacking, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): setBackingFile(url)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { backingError = error.localizedDescription }
                }
            }
        #endif
    }

    private func setBackingFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard AudioLibrary.isAudio(url), let bookmark = SongLibraryModel.bookmark(url) else {
            backingError = "Choose an accessible audio file."
            return
        }
        editor.draft.backingImport = SongBackingImport(bookmark: bookmark, name: url.lastPathComponent)
        backingError = nil
    }

    @ViewBuilder private var metadataFields: some View {
        field("Song key", text: $editor.draft.key, prompt: "C, F# or Am")
        capoField
        field("BPM", text: $editor.draft.tempo, prompt: "120")
        field("Time signature", text: $editor.draft.timeSignature, prompt: "4/4")
        field("Length", text: $editor.draft.duration, prompt: "3:45")
    }
    private var capoField: some View {
        let frets = (1...5).map(String.init)
        let current = draft.capo
        let off = current == "0" ? "0" : ""
        return VStack(alignment: .leading, spacing: 5) {
            Text("Capo").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("Capo", selection: $editor.draft.capo) {
                Text("Off").tag(off)
                ForEach(frets, id: \.self) { fret in Text(fret).tag(fret) }
                if !current.isEmpty && current != off && !frets.contains(current) {
                    Text(current).tag(current)
                }
            }.labelsHidden().pickerStyle(.menu).accessibilityIdentifier("song-capo-picker")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var playlistField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Playlists").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("All Songs only") { editor.draft.playlistIDs = [] }
                if let playlists = library.library?.playlists, !playlists.isEmpty {
                    Divider()
                    ForEach(playlists) { playlist in
                        Toggle(playlist.title, isOn: Binding(get: { editor.draft.playlistIDs.contains(playlist.id) }, set: { selected in
                            if selected { editor.draft.playlistIDs.insert(playlist.id) }
                            else { editor.draft.playlistIDs.remove(playlist.id) }
                        }))
                    }
                }
            } label: {
                Text(playlistSummary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.hoverHighlight().accessibilityLabel("Song playlists").accessibilityValue(playlistSummary)
                .help("Every song appears in All Songs. Select any additional playlists.")
        }
    }
    private var playlistSummary: String {
        let selected = (library.library?.playlists ?? []).filter { draft.playlistIDs.contains($0.id) }
        if selected.isEmpty { return "All Songs only" }
        return selected.count == 1 ? selected[0].title : "\(selected.count) playlists"
    }
    private func field(_ name: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).hoverHighlight().accessibilityLabel(name)
        }
    }
}

private struct SongJamSetupFields: View {
    @Binding var draft: SongDraft
    let library: SongLibraryModel
    let looper: LooperModel
    @Binding var backingError: String?
    let chooseLoop: () -> Void
    let chooseBacking: () -> Void
    @State private var loopBPM: Double?
    @State private var loopError: String?

    private var backingName: String? {
        if let pending = draft.backingImport { return pending.name }
        if let path = draft.backingTrackPath {
            return path.isEmpty ? nil : path.split(separator: "/").last.map(String.init)
        }
        return library.backingURL(songID: draft.id)?.lastPathComponent
    }

    var body: some View {
        Section {
            attachmentRow("Saved Loop", name: draft.savedLoopName.map { String($0.dropLast(".jamloop".count)) },
                          choose: chooseLoop, remove: { draft.savedLoopName = nil })
            if let loopBPM {
                HStack {
                    Text("Loop tempo: " + loopBPM.formatted(.number.precision(.fractionLength(0...2))) + " BPM")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if Double(draft.tempo) != loopBPM {
                        Button("Use Loop BPM") { draft.tempo = String(loopBPM) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            attachmentRow("Backing Track", name: backingName, choose: chooseBacking, remove: {
                draft.backingImport = nil
                draft.backingTrackPath = draft.original.backingTrackPath == nil && library.backingURL(songID: draft.id) == nil ? nil : ""
                backingError = nil
            })
            if let loopError { Text(loopError).font(.caption).foregroundStyle(.orange) }
            if let backingError { Text(backingError).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Jam Setup").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: draft.savedLoopName) {
            loopBPM = nil
            loopError = nil
            guard let name = draft.savedLoopName,
                  let url = LibraryFiles.songLoopURL(named: name, in: library.folderURL) else { return }
            do {
                let bpm = try await looper.savedLoopBPM(url)
                if !Task.isCancelled { loopBPM = bpm }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { loopError = "Couldn’t read the saved loop: " + error.localizedDescription }
            }
        }
    }

    private func attachmentRow(_ title: String, name: String?, choose: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).fixedSize()
            Spacer(minLength: 8)
            if let name {
                Text(name).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(name)
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(JamIconStyle())
                    .accessibilityLabel("Remove \(title) link").help("Remove \(title) link")
            }
            Button(action: choose) { Image(systemName: "folder") }
                .buttonStyle(JamIconStyle())
                .accessibilityLabel(title)
                .accessibilityValue(name ?? "No file selected")
                .help(name == nil ? "Browse for \(title.lowercased())" : "Replace \(title.lowercased())")
        }
    }
}

private struct ChordProExport: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
