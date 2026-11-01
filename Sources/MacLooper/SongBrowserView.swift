import SwiftUI
import JamCore

struct SongBrowserView: View {
    @ObservedObject var library: SongLibraryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Songs").font(.title3.weight(.semibold)).padding(.top, 16)
            TextField("Search songs", text: $library.query).textFieldStyle(.roundedBorder)
            Picker("Playlist", selection: $library.playlistID) {
                Text("All Songs").tag(String?.none)
                ForEach(library.library?.playlists ?? []) { list in Text(list.title).tag(Optional(list.id)) }
            }.labelsHidden()
            List(selection: $library.selectedSongID) {
                ForEach(Array(library.songs.enumerated()), id: \.offset) { _, song in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).lineLimit(2)
                        if !song.artist.isEmpty { Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.padding(.vertical, 3).tag(song.id)
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Text(library.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                .padding(.bottom, 12).accessibilityLabel("Library status: \(library.status)")
        }.padding(.horizontal, 12).frame(maxHeight: .infinity)
            .onChange(of: library.playlistID) { _, _ in
                if let id = library.selectedSongID, !library.songs.contains(where: { $0.id == id }) { library.selectedSongID = nil }
            }
    }
}
