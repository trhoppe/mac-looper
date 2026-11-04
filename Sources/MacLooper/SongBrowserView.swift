import SwiftUI
import JamCore

struct SongBrowserView: View {
    @ObservedObject var library: SongLibraryModel
    var onSelectSong: () -> Void = {}
    var onAddSong: () -> Void = {}
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    private var selection: Binding<String?> {
        Binding(get: { library.selectedSongID }, set: { id in
            library.selectedSongID = id
            if id != nil { onSelectSong() }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Songs").font(.title3.weight(.semibold)).fixedSize()
                    Spacer(minLength: 0)
                    Button(action: onAddSong) { Image(systemName: "plus").frame(width: 28, height: 28) }
                        .buttonStyle(JamPlainButtonStyle()).accessibilityLabel("Add song").help("Add a new song")
                        .disabled(library.library == nil || library.syncing || library.saving)
                    Button {
                        searching.toggle(); searchFocused = searching
                        if !searching { library.query = "" }
                    } label: { Image(systemName: "magnifyingglass").frame(width: 28, height: 28) }.buttonStyle(JamPlainButtonStyle())
                        .accessibilityLabel("Search songs").accessibilityValue(searching ? "Shown" : "Hidden")
                    Picker("Sort by", selection: $library.sortOrder) {
                        ForEach(SongSortOrder.allCases, id: \.self) { order in Text(order.title).tag(order) }
                    }.labelsHidden().pickerStyle(.menu).controlSize(.regular).font(.callout).fixedSize().hoverHighlight()
                        .accessibilityLabel("Sort songs by").accessibilityValue(library.sortOrder.title)
                }
                if searching {
                    TextField("Search songs", text: $library.query).textFieldStyle(.roundedBorder).hoverHighlight().focused($searchFocused)
                }
                Picker("Playlist", selection: $library.playlistID) {
                    Text("All Songs").tag(String?.none)
                    ForEach(library.library?.playlists ?? []) { list in Text(list.title).tag(Optional(list.id)) }
                }.labelsHidden().controlSize(.regular).font(.callout).hoverHighlight()
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            List(selection: selection) {
                ForEach(library.songs) { song in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).lineLimit(2)
                        if !song.artist.isEmpty { Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 6).frame(minHeight: 44)
                        .browserRowHighlight(selected: library.selectedSongID == song.id)
                        // Cover the native list's horizontal selection gutters too.
                        #if os(macOS)
                        .padding(.horizontal, -9)
                        #endif
                        .tag(song.id)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .simultaneousGesture(TapGesture().onEnded {
                            // A repeat tap must reveal a hidden chart too.
                            library.selectedSongID = song.id
                            onSelectSong()
                        })
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).tint(.gray).accentColor(.gray)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                #if os(iOS)
                // Preserve the Songs popover's outline beside the opaque rows.
                .clipped().padding(.horizontal, 1)
                #endif
            Text(library.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                .padding(.horizontal, 16).padding(.vertical, 12).accessibilityLabel("Library status: \(library.status)")
        }.frame(maxHeight: .infinity)
            #if os(iOS)
            .background(Color(red: 0.075, green: 0.085, blue: 0.10))
            #endif
            .onAppear { searching = !library.query.isEmpty }
            .onChange(of: library.playlistID) { _, _ in
                if let id = library.selectedSongID, !library.songs.contains(where: { $0.id == id }) { library.selectedSongID = nil }
            }
    }
}
