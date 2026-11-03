import Foundation
import SwiftUI
import JamCore

@MainActor final class SongEditorModel: ObservableObject {
    @Published var draft: SongDraft { didSet { if !restoring { persist() } } }
    @Published private(set) var recovering = true
    @Published private(set) var recovered = false
    @Published private(set) var recoveryError: String?
    private let library: SongLibraryModel
    private var restoring = false
    private var writeTask: Task<Void, Never>?
    init(draft: SongDraft, library: SongLibraryModel) { self.draft = draft; self.library = library }
    func restore() async {
        defer { recovering = false }
        do {
            if let saved = try await library.recoveryStore.drafts(in: library.destination).first(where: { $0.id == draft.id }) {
                restoring = true
                var restored = saved.draft
                if !restored.isNew, restored.originalPlaylistIDs == nil, let current = library.library {
                    var upgraded = SongDraft(song: restored.original, playlistIDs: current.playlistIDs(containing: restored.id))
                    upgraded.chordPro = restored.chordPro; restored = upgraded
                }
                draft = restored; restoring = false; recovered = true
            }
        } catch { recoveryError = "Couldn’t read recovered edits: " + error.localizedDescription }
    }
    private func persist() {
        let snapshot = draft, destination = library.destination
        let sequence = library.nextDraftSequence()
        let store = library.recoveryStore
        writeTask = Task {
            do {
                try await store.write(snapshot.hasChanges ? RecoveredSongDraft(draft: snapshot, library: destination) : nil,
                                      library: destination, songID: snapshot.id, sequence: sequence)
                recoveryError = nil
            } catch { recoveryError = "Couldn’t keep a recovery copy: " + error.localizedDescription }
        }
    }
    func keepForLater() async throws {
        persist()
        if let writeTask { await writeTask.value }
        if let recoveryError { throw AudioFailure(message: recoveryError) }
        await library.refreshRecoveredDrafts()
    }
    func clearRecovery() async throws {
        if let writeTask { await writeTask.value }
        try await library.recoveryStore.write(nil, library: library.destination, songID: draft.id, sequence: library.nextDraftSequence())
        await library.refreshRecoveredDrafts()
    }
}
