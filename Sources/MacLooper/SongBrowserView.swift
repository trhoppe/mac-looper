import SwiftUI
import JamCore

struct SongBrowserView: View {
    @ObservedObject var library: SongLibraryModel
    var onSelectSong: () -> Void = {}
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
                HStack(spacing: 4) {
                    Text("Songs").font(.title3.weight(.semibold)).fixedSize()
                    Spacer(minLength: 0)
                    Button {
                        searching.toggle(); searchFocused = searching
                        if !searching { library.query = "" }
                    } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain)
                        .accessibilityLabel("Search songs").accessibilityValue(searching ? "Shown" : "Hidden")
                    Picker("Sort by", selection: $library.sortOrder) {
                        ForEach(SongSortOrder.allCases, id: \.self) { order in Text(order.title).tag(order) }
                    }.labelsHidden().pickerStyle(.menu).font(.caption).fixedSize()
                        .accessibilityLabel("Sort songs by").accessibilityValue(library.sortOrder.title)
                }
                if searching {
                    TextField("Search songs", text: $library.query).textFieldStyle(.roundedBorder).focused($searchFocused)
                }
                Picker("Playlist", selection: $library.playlistID) {
                    Text("All Songs").tag(String?.none)
                    ForEach(library.library?.playlists ?? []) { list in Text(list.title).tag(Optional(list.id)) }
                }.labelsHidden()
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            List(selection: selection) {
                ForEach(library.songs) { song in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).lineLimit(2)
                        if !song.artist.isEmpty { Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).hoverHighlight().tag(song.id)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)).listRowSeparator(.hidden)
                        .simultaneousGesture(TapGesture().onEnded {
                            // A repeat tap must reveal a hidden chart too.
                            library.selectedSongID = song.id
                            onSelectSong()
                        })
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
            Text(library.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                .padding(.horizontal, 16).padding(.vertical, 12).accessibilityLabel("Library status: \(library.status)")
        }.frame(maxHeight: .infinity)
            .onAppear { searching = !library.query.isEmpty }
            .onChange(of: library.playlistID) { _, _ in
                if let id = library.selectedSongID, !library.songs.contains(where: { $0.id == id }) { library.selectedSongID = nil }
            }
    }
}
