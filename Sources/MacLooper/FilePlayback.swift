import Foundation
import AVFoundation

struct FilePlaybackSnapshot: Sendable {
    let duration: Double
    let position: Double
    let playing: Bool
}

// File opening runs on this actor; the shared engine owns playback and mixing.
actor FilePlayback {
    private var session: UUID?
    func load(_ url: URL, session: UUID, volume: Float, repeating: Bool) async throws -> FilePlaybackSnapshot {
        try Task.checkCancellation()
        let previous = self.session
        self.session = session
        await AudioEngineHost.shared.unloadFile(session: previous)
        try Task.checkCancellation()
        guard self.session == session else { throw CancellationError() }
        let asset = try PlaybackAsset(url)
        try Task.checkCancellation()
        guard self.session == session else { throw CancellationError() }
        await AudioEngineHost.shared.loadFile(asset, session: session, volume: volume, repeating: repeating)
        return FilePlaybackSnapshot(duration: asset.duration, position: 0, playing: false)
    }
    func play(session: UUID, output: AudioDevice) async throws {
        guard self.session == session else { return }
        try await AudioEngineHost.shared.playFile(session: session, output: output)
    }
    func pause(session: UUID) async { guard self.session == session else { return }; await AudioEngineHost.shared.pauseFile(session: session) }
    func stop(session: UUID) async { guard self.session == session else { return }; await AudioEngineHost.shared.stopFile(session: session) }
    func seek(session: UUID, to seconds: Double) async { guard self.session == session else { return }; await AudioEngineHost.shared.seekFile(session: session, to: seconds) }
    func configure(session: UUID, volume: Float, repeating: Bool) async { guard self.session == session else { return }; await AudioEngineHost.shared.configureFile(session: session, volume: volume, repeating: repeating) }
    func snapshot(session: UUID) async -> FilePlaybackSnapshot? { guard self.session == session else { return nil }; return await AudioEngineHost.shared.fileSnapshot(session: session) }
    func unload(session expected: UUID? = nil) async {
        if let expected, session != expected { return }
        await AudioEngineHost.shared.unloadFile(session: session); session = nil
    }
}
