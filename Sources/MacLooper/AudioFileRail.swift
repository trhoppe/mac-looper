import SwiftUI
import UniformTypeIdentifiers

struct AudioFileRail: View {
    @ObservedObject var model: AudioFilePlayerModel
    @Environment(\.jamBrowserBounds) private var browserBounds
    @State private var browserAnchor: CGRect = .zero
    let accent: Color
    var compact = false
    var minimumHeight: CGFloat? = nil
    @State private var showingBrowser = false
    @State private var dropTargeted = false
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    private var selection: Binding<URL?> {
        Binding(get: { model.selected?.id }, set: { id in
            if let track = model.tracks.first(where: { $0.id == id }) {
                model.select(track)
                showingBrowser = false
            }
        })
    }
    var body: some View {
        popupRail
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: openDroppedFile)
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(accent, lineWidth: 2)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                    .opacity(dropTargeted ? 1 : 0).allowsHitTesting(false)
            }
            .onAppear { searching = !model.query.isEmpty }
    }
    private func openDroppedFile(_ providers: [NSItemProvider]) -> Bool {
        let type = UTType.fileURL.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
            let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            Task { @MainActor in
                if let url {
                    model.selectFile(url, autoplay: true)
                    showingBrowser = false
                } else {
                    model.error = error?.localizedDescription ?? "Couldn’t open the dropped file."
                }
            }
        }
        return true
    }
    private var popupRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { showingBrowser.toggle() } label: {
                    HStack(spacing: 8) {
                        Text("Audio Files").font(.title3.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }.buttonStyle(JamPlainButtonStyle())
                    .padding(.leading, -8)
                    .accessibilityLabel("Browse audio files")
                    .accessibilityValue(showingBrowser ? "Shown" : "Hidden")
                    #if os(macOS)
                    .anchorPreference(key: AudioBrowserPopupKey.self, value: .bounds) { anchor in
                        showingBrowser ? AudioBrowserPopupRequest(anchor: anchor, content: AnyView(browser),
                            close: { showingBrowser = false }) : nil
                    }
                    #else
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { browserAnchor = $0 }
                    .popover(isPresented: $showingBrowser) { popupBrowser }
                    #endif
                Spacer(minLength: 8)
                audioOpenButton("Open audio file…", icon: "doc.badge.plus") { model.requestingFile = true }
                folderButton
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            player.padding(18)
            if !showingBrowser, let error = model.error { errorBanner(error) }
        }.frame(maxWidth: .infinity, minHeight: minimumHeight, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
            .background(Color(red: 0.075, green: 0.085, blue: 0.10)).tint(accent)
    }
    private var popupBrowser: some View {
        // Portrait places this header midway down the app. A side-opening popup
        // can use the whole app height instead of only the space below the header.
        let opensBeside = browserAnchor.maxX + 356 <= browserBounds.maxX - 8
        let height = opensBeside ? browserBounds.height * 0.9 - 8 :
            browserBounds.minY + browserBounds.height * 0.9 - browserAnchor.maxY - 12
        return browser.frame(width: 340, height: max(0, height))
        #if os(iOS)
            .presentationCompactAdaptation(.popover)
        #endif
    }
    private var folderButton: some View {
        audioOpenButton("Open audio folder…", icon: "folder.badge.plus") { model.chooseFolder() }
    }
    private func audioOpenButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 19, height: 16)
        }
        .buttonStyle(JamButtonStyle())
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }
    private var browser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Audio Files").font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        searching.toggle(); searchFocused = searching
                        if !searching { model.query = "" }
                    } label: { Image(systemName: "magnifyingglass").frame(width: 28, height: 28) }.buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Search audio files")
                    #if os(macOS)
                    folderButton
                    #endif
                }
                if let folder = model.folder {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text("\(model.trackCount)").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary).help(folder.path)
                    if searching {
                        TextField("Search files or folders", text: $model.query)
                            .textFieldStyle(.roundedBorder).hoverHighlight().focused($searchFocused).accessibilityLabel("Search audio files")
                    }
                }
            }.padding(18)
            Divider()
            ZStack {
                if model.scanning {
                    VStack(spacing: 12) { ProgressView().controlSize(.small); Text("Finding audio files…").font(.callout).foregroundStyle(.secondary) }
                } else if model.groups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.music").font(.system(size: 32)).foregroundStyle(accent.opacity(0.7))
                        Text(model.folder == nil ? "Your backing tracks, in one place" : "No audio files found").font(.callout)
                        Text(model.folder == nil ? "Open a folder to browse its audio files and subfolders." : "Choose another folder to browse your audio files.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        #if os(macOS)
                        Button("Open Folder…") { model.chooseFolder() }.buttonStyle(JamButtonStyle())
                        #else
                        Text("Use the folder button beside Audio Files to choose a folder.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        #endif
                    }.padding(24)
                } else if model.visibleGroups.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                } else {
                    List(selection: selection) {
                        ForEach(model.visibleGroups) { group in
                            Section {
                                ForEach(group.tracks) { track in
                                    #if os(iOS)
                                    Button {
                                        model.select(track)
                                        showingBrowser = false
                                    } label: { trackRow(track) }
                                        .buttonStyle(.plain)
                                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                                    #else
                                    trackRow(track).tag(track.id).help(track.url.path)
                                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                                    #endif
                                }
                            } header: {
                                HStack {
                                    Text(group.title).lineLimit(2)
                                    Spacer(minLength: 4)
                                    Text("\(group.tracks.count)").monospacedDigit().fixedSize()
                                }.font(.caption.weight(.medium)).textCase(nil).padding(.trailing, 16)
                            }
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden).tint(.gray).accentColor(.gray)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = model.scanNotice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8) }
            if let error = model.error { errorBanner(error) }
        }
            .background(Color(red: 0.075, green: 0.085, blue: 0.10)).tint(accent)
    }
    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(error).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Dismiss audio file error")
        }.padding(12).background(.orange.opacity(0.08))
    }
    private func trackRow(_ track: AudioTrack) -> some View {
        HStack(spacing: 9) {
            Image(systemName: model.selected?.id == track.id && model.playing ? "speaker.wave.2.fill" : "music.note")
                .font(.caption).foregroundStyle(model.selected?.id == track.id ? accent : .secondary)
                .frame(width: 16)
            Text(track.title).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
        }.padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 8).frame(minHeight: 32)
            .browserRowHighlight(selected: model.selected?.id == track.id, background: Color(red: 0.075, green: 0.085, blue: 0.10))
    }
    private var player: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path").foregroundStyle(accent).font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selected?.title ?? "Select an audio file").font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(model.loading ? "Loading…" : model.selected.map { $0.directory.isEmpty ? model.folder?.lastPathComponent ?? "" : $0.directory } ?? "Drop an audio file here or open one.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 3) {
                Slider(value: Binding(get: { scrubbing ? scrubPosition : min(model.position, max(model.duration, 0.01)) },
                                      set: { scrubPosition = $0; if !scrubbing { model.seek($0) } }), in: 0...max(model.duration, 0.01),
                       onEditingChanged: { editing in
                    if editing { scrubPosition = model.position; scrubbing = true }
                    else { model.seek(scrubPosition); scrubbing = false }
                }).hoverHighlight().disabled(model.duration <= 0 || model.loading).accessibilityLabel("File playback position")
                HStack {
                    Text(Self.time(scrubbing ? scrubPosition : model.position))
                    Spacer()
                    Text(Self.time(model.duration))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Button { model.restart() } label: { playerIcon("backward.end.fill") }
                    .disabled(model.duration <= 0 || model.loading).accessibilityLabel("Restart current song")
                    .help("Restart current song")
                Button { model.skip(-10) } label: { playerIcon("gobackward.10") }
                    .disabled(model.duration <= 0 || model.loading).accessibilityLabel("Back 10 seconds")
                Button { model.togglePlay() } label: {
                    playerIcon((model.playing || model.startingPlayback) ? "pause.fill" : "play.fill", primary: true)
                }.disabled(model.duration <= 0 || model.loading).accessibilityLabel((model.playing || model.startingPlayback) ? "Pause file" : "Play file")
                Button { model.stop() } label: { playerIcon("stop.fill") }
                    .disabled(model.selected == nil || model.loading).accessibilityLabel("Stop file")
                Button { model.skip(10) } label: { playerIcon("goforward.10") }
                    .disabled(model.duration <= 0 || model.loading).accessibilityLabel("Forward 10 seconds")
                Button { model.step(1) } label: { playerIcon("forward.end.fill") }
                    .disabled(!model.canStep(1)).accessibilityLabel("Next audio file")
                Button { model.repeatTrack.toggle() } label: {
                    playerIcon("repeat.1").foregroundStyle(model.repeatTrack ? accent : .secondary)
                }.help(model.repeatTrack ? "Repeat this file: on" : "Repeat this file: off")
                    .accessibilityLabel("Repeat file").accessibilityValue(model.repeatTrack ? "On" : "Off")
            }.buttonStyle(JamPlainButtonStyle())
            VolumeControl(volume: $model.volume, name: "File player")
        }
    }
    private func playerIcon(_ name: String, primary: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: primary ? 25 : 20))
            .frame(minWidth: 32, maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
    }
    static func time(_ value: Double) -> String {
        let n = value.isFinite ? max(0, Int(value)) : 0
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
            : String(format: "%d:%02d", n / 60, n % 60)
    }
}
