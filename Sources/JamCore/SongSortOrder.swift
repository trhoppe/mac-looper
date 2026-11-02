import Foundation

public enum SongSortOrder: String, CaseIterable, Sendable {
    case songName, artistName
    public var title: String { self == .songName ? "Song name" : "Artist name" }

    public func apply(to songs: [LibrarySong], query: String) -> [LibrarySong] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return songs.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }.sorted { lhs, rhs in
            if self == .artistName {
                let a = lhs.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let b = rhs.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                if a.isEmpty != b.isEmpty { return !a.isEmpty }
                let order = a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: .current)
                if order != .orderedSame { return order == .orderedAscending }
            }
            let order = lhs.title.compare(rhs.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: .current)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}
