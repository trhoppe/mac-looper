import Foundation
import AVFoundation

struct FilePlaybackSnapshot: Sendable {
    let duration: Double
    let position: Double
    let playing: Bool
    let intendsToPlay: Bool
}

// File opening runs on this actor; the shared engine owns playback and mixing.
actor FilePlayback {
    private let host: AudioEngineHost?
    init(host: AudioEngineHost? = nil) { self.host = host }
    @MainActor private var engine: AudioEngineHost { host ?? .shared }

    private var session: UUID?
    func load(_ url: URL, session: UUID, volume: Float, repeating: Bool) async throws -> FilePlaybackSnapshot {
        try Task.checkCancellation()
        let previous = self.session
        self.session = session
        await engine.unloadFile(session: previous)
        try Task.checkCancellation()
        guard self.session == session else { throw CancellationError() }
        let asset = try PlaybackAsset(url)
        try Task.checkCancellation()
        guard self.session == session else { throw CancellationError() }
        await engine.loadFile(asset, session: session, volume: volume, repeating: repeating)
        return FilePlaybackSnapshot(duration: asset.duration, position: 0, playing: false, intendsToPlay: false)
    }
    func play(session: UUID, output: AudioDevice, requestedIntent: UUID? = nil, useSystemBuffer: Bool = false) async throws {
        guard self.session == session else { return }
        try await engine.playFile(session: session, output: output, requestedIntent: requestedIntent, useSystemBuffer: useSystemBuffer)
    }
    func pause(session: UUID) async { guard self.session == session else { return }; await engine.pauseFile(session: session) }
    func stop(session: UUID) async { guard self.session == session else { return }; await engine.stopFile(session: session) }
    func seek(session: UUID, to seconds: Double) async { guard self.session == session else { return }; await engine.seekFile(session: session, to: seconds) }
    func configure(session: UUID, volume: Float, repeating: Bool) async { guard self.session == session else { return }; await engine.configureFile(session: session, volume: volume, repeating: repeating) }
    func snapshot(session: UUID) async -> FilePlaybackSnapshot? { guard self.session == session else { return nil }; return await engine.fileSnapshot(session: session) }
    func unload(session expected: UUID? = nil) async {
        if let expected, session != expected { return }
        await engine.unloadFile(session: session); session = nil
    }
}
