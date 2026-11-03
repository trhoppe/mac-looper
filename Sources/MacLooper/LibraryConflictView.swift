import SwiftUI
import JamCore

struct LibraryConflictView: View {
    @ObservedObject var library: SongLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = "current"
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?
    private var selected: LibraryConflictCopy? { library.conflicts.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Review library versions").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.disabled(busy)
            }
            Text("Choose the library you want to keep. Exact copies of every version are kept in Library Conflicts beside library.json. Unsaved song drafts stay available.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(library.conflicts.enumerated()), id: \.element.id) { index, copy in
                Button { selection = copy.id } label: {
                    HStack {
                        Image(systemName: selection == copy.id ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading) {
                            Text(copy.isCurrent ? "Current library" : "iCloud version \(index)")
                            if let date = copy.date { Text(date, format: .dateTime).font(.caption) }
                            if let device = copy.device { Text(device).font(.caption) }
                        }
                        Spacer()
                        Text(copy.isValid ? "\(copy.songs.count) songs" : "Unreadable · copy preserved").font(.caption)
                    }.padding(10).background(selection == copy.id ? Color.cyan.opacity(0.10) : Color.clear)
                }.buttonStyle(JamPlainButtonStyle())
            }
            Divider()
            if let selected {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(selected.songs) { song in
                            Text(song.title + " · " + song.artist).font(.headline)
                            Text(song.chordPro).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("Refresh versions") { Task { await library.refresh() } }.disabled(busy)
                Spacer()
                Button(busy ? "Applying…" : "Use selected version") { confirming = true }
                    .buttonStyle(JamButtonStyle(prominent: true)).disabled(busy || selected?.isValid != true || library.editing)
            }
        }.padding(20).frame(minWidth: 540, idealWidth: 780, minHeight: 480, idealHeight: 700)
        .confirmationDialog("Use this library version?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Use selected library") {
                guard let selected else { return }
                busy = true
                Task {
                    do { try await library.resolveConflict(using: selected); dismiss() }
                    catch { self.error = error.localizedDescription; await library.refresh() }
                    busy = false
                }
            }
        } message: { Text("This chooses the entire library, including its songs and folders. All versions are backed up before anything is replaced.") }
    }
}
