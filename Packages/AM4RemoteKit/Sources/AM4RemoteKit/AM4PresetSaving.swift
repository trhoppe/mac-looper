import Foundation

@MainActor enum AM4PresetSaveOperation {
    enum Result { case saved, alreadyClean }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func run(_ command: AM4PresetSaveCommand, requireEdited: Bool,
                    readLocation: () async throws -> Int, readSnapshot: () async throws -> AM4Snapshot,
                    commit: () async throws -> Void, readStoredName: () async throws -> String,
                    sessionIsCurrent: () -> Bool,
                    wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }) async throws -> Result {
        guard command.isValid, sessionIsCurrent() else { throw Failure(message: "The preset save request is no longer current.") }
        let before = try await readLocation()
        let snapshot = try await readSnapshot()
        let last = try await readLocation()
        guard sessionIsCurrent(), before == last, command.matches(location: last, snapshot: snapshot) else {
            throw Failure(message: "The current preset or scene changed. Review it before saving.")
        }
        guard let edited = snapshot.edited else { throw Failure(message: "The AM4 did not report whether the preset has unsaved changes.") }
        if !edited {
            guard !requireEdited else { throw Failure(message: "The AM4 is still updating its edited state. Try Save again in a moment.") }
            return .alreadyClean
        }
        // Exactly one permanent write; failures never trigger an automatic retry.
        try await commit()
        for _ in 0..<12 {
            try await wait()
            let first = try await readLocation()
            let observed = try await readSnapshot()
            let last = try await readLocation()
            guard sessionIsCurrent(), first == last, command.matches(location: last, snapshot: observed) else {
                throw Failure(message: "Save was acknowledged, but the current preset changed during verification.")
            }
            if observed.edited == false {
                let name = try await readStoredName()
                guard sessionIsCurrent(), name == command.snapshot.name, try await readLocation() == command.location else {
                    throw Failure(message: "AM4 acknowledged Save, but the stored preset could not be verified.")
                }
                return .saved
            }
        }
        throw Failure(message: "Save was acknowledged, but the AM4 still reports unsaved changes. Review it before trying again.")
    }
}
