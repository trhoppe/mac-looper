import SwiftUI

struct AudioFileRail: View {
    @ObservedObject var model: AudioFilePlayerModel
    let accent: Color
    var compact = false
    var expanded = false
    @AppStorage("filePlayerHeight") private var playerHeight = 230.0
    @State private var showingBrowser = false
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    private var selection: Binding<URL?> {
        Binding(get: { model.selected?.id }, set: { id in
            if let track = model.tracks.first(where: { $0.id == id }) { model.select(track) }
        })
    }
    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Backing Track").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Browse…") { showingBrowser = true }
                            .popover(isPresented: $showingBrowser) { AudioFileRail(model: model, accent: accent).frame(height: 560) }
                    }
                    player
                }.padding(12).background(.white.opacity(0.025))
            } else { fullRail }
        }.onAppear { searching = !model.query.isEmpty }
    }
    private var fullRail: some View {
        ResizableSplit(axis: .vertical, side: .trailing, size: $playerHeight, defaultSize: 230,
                       minimumLeading: 160, minimumTrailing: 210, label: "Resize file list and player") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Audio Files").font(.title3.weight(.semibold))
                        Spacer()
                        Button {
                            searching.toggle(); searchFocused = searching
                            if !searching { model.query = "" }
                        } label: { Image(systemName: "magnifyingglass").frame(width: 28, height: 28) }.buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Search audio files")
                        Button { model.chooseFolder() } label: { Image(systemName: "folder.badge.plus") }
                            .buttonStyle(JamButtonStyle()).help("Open a folder and include all of its subfolders")
                            .accessibilityLabel("Open audio folder")
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
                            Button("Open Folder…") { model.chooseFolder() }.buttonStyle(JamButtonStyle())
                        }.padding(24)
                    } else if model.visibleGroups.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    } else {
                        List(selection: selection) {
                            ForEach(model.visibleGroups) { group in
                                Section {
                                    ForEach(group.tracks) { track in
                                        HStack(spacing: 9) {
                                            Image(systemName: model.selected?.id == track.id && model.playing ? "speaker.wave.2.fill" : "music.note")
                                                .font(.caption).foregroundStyle(model.selected?.id == track.id ? accent : .secondary)
                                                .frame(width: 16)
                                            Text(track.title).font(.callout).lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 4)
                                        }.padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 32)
                                            .browserRowHighlight(selected: model.selected?.id == track.id, background: Color(red: 0.075, green: 0.085, blue: 0.10))
                                            .tag(track.id).help(track.url.path)
                                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                                    }
                                } header: {
                                    HStack {
                                        Text(group.title).lineLimit(2)
                                        Spacer(minLength: 4)
                                        Text("\(group.tracks.count)").monospacedDigit()
                                    }.font(.caption.weight(.medium)).textCase(nil)
                                }
                            }
                        }.listStyle(.sidebar).scrollContentBackground(.hidden).tint(.gray).accentColor(.gray)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = model.scanNotice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8) }
                if let error = model.error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(JamPlainButtonStyle())
                    }.padding(12).background(.orange.opacity(0.08))
                }
            }
        } trailing: {
            GeometryReader { geo in
                ScrollView {
                    player.padding(18).frame(maxWidth: .infinity, minHeight: geo.size.height)
                }.background(.white.opacity(0.025))
            }
        }
        .frame(width: expanded ? nil : 340)
        .frame(maxWidth: expanded ? .infinity : nil)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.075, green: 0.085, blue: 0.10))
        .tint(accent)
    }
    private var player: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path").foregroundStyle(accent).font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selected?.title ?? "Select an audio file").font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(model.loading ? "Loading…" : model.selected.map { $0.directory.isEmpty ? model.folder?.lastPathComponent ?? "" : $0.directory } ?? "Ready for something to play along with")
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
                Button { model.step(-1) } label: { playerIcon("backward.end.fill") }
                    .disabled(!model.canStep(-1)).accessibilityLabel("Previous audio file")
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
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1).hoverHighlight().accessibilityLabel("File player volume")
                Text("\(Int((model.volume * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
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
