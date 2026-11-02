import SwiftUI
import JamCore

struct SongBrowserView: View {
    @ObservedObject var library: SongLibraryModel
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Songs").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    searching.toggle(); searchFocused = searching
                    if !searching { library.query = "" }
                } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain)
                    .accessibilityLabel("Search songs").accessibilityValue(searching ? "Shown" : "Hidden")
            }.padding(.top, 16)
            if searching {
                TextField("Search songs", text: $library.query).textFieldStyle(.roundedBorder).focused($searchFocused)
            }
            Picker("Playlist", selection: $library.playlistID) {
                Text("All Songs").tag(String?.none)
                ForEach(library.library?.playlists ?? []) { list in Text(list.title).tag(Optional(list.id)) }
            }.labelsHidden()
            List(selection: $library.selectedSongID) {
                ForEach(library.songs) { song in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).lineLimit(2)
                        if !song.artist.isEmpty { Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).hoverHighlight().tag(song.id)
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Text(library.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                .padding(.bottom, 12).accessibilityLabel("Library status: \(library.status)")
        }.padding(.horizontal, 12).frame(maxHeight: .infinity)
            .onAppear { searching = !library.query.isEmpty }
            .onChange(of: library.playlistID) { _, _ in
                if let id = library.selectedSongID, !library.songs.contains(where: { $0.id == id }) { library.selectedSongID = nil }
            }
    }
}
