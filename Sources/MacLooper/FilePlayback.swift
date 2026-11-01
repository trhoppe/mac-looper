import Foundation
import AVFoundation
import CoreAudio

struct FilePlaybackSnapshot: Sendable {
    let duration: Double
    let position: Double
    let playing: Bool
}

// Native file decoding/playback stays on its own actor, never on the UI or looper's
// realtime thread. It has no input node and cannot feed samples into loop capture.
actor FilePlayback {
    private var player: AVAudioPlayer?
    private var session: UUID?
    private var completed = false
    private var wasPlaying = false

    func load(_ url: URL, session: UUID, volume: Float, repeating: Bool) throws -> FilePlaybackSnapshot {
        try Task.checkCancellation()
        player?.stop(); player = nil
        self.session = session; completed = false; wasPlaying = false
        let next = try AVAudioPlayer(contentsOf: url)
        guard next.duration.isFinite, next.duration > 0 else { throw AudioFailure(message: "This audio file has no playable duration.") }
        next.volume = volume; next.numberOfLoops = repeating ? -1 : 0
        player = next
        return snapshot(session: session)!
    }
    func play(session: UUID, output: AudioDevice) throws {
        guard self.session == session, let player else { return }
        guard AudioDevices.alive(output.id), AudioDevices.string(output.id, kAudioDevicePropertyDeviceUID) == output.uid else {
            throw AudioFailure(message: "The selected output is disconnected. Choose an output in Audio Settings.")
        }
        try AudioDevices.require32Frames(output.id, name: output.name)
        player.currentDevice = output.uid
        guard player.currentDevice == output.uid else { throw AudioFailure(message: "Could not route the file player to \(output.name).") }
        if completed || player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.prepareToPlay() else { throw AudioFailure(message: "Could not prepare this audio file for playback.") }
        try AudioDevices.require32Frames(output.id, name: output.name)
        guard player.play() else { throw AudioFailure(message: "Could not play this audio file through \(output.name).") }
        completed = false; wasPlaying = true
    }
    func pause(session: UUID) {
        guard self.session == session else { return }
        player?.pause(); wasPlaying = false
    }
    func stop(session: UUID) {
        guard self.session == session else { return }
        // Pause + seek keeps the selected file ready without rebuilding its decoder.
        player?.pause(); player?.currentTime = 0; completed = false; wasPlaying = false
    }
    func seek(session: UUID, to seconds: Double) {
        guard self.session == session, let player, seconds.isFinite else { return }
        player.currentTime = min(player.duration, max(0, seconds)); completed = false
    }
    func configure(session: UUID, volume: Float, repeating: Bool) {
        guard self.session == session else { return }
        player?.setVolume(min(1, max(0, volume)), fadeDuration: 0.02)
        player?.numberOfLoops = repeating ? -1 : 0
    }
    func snapshot(session: UUID) -> FilePlaybackSnapshot? {
        guard self.session == session, let player else { return nil }
        if wasPlaying && !player.isPlaying { completed = true; wasPlaying = false }
        return FilePlaybackSnapshot(duration: player.duration, position: completed ? player.duration : player.currentTime, playing: player.isPlaying)
    }
    func unload(session expected: UUID? = nil) {
        if let expected, session != expected { return }
        player?.stop(); player = nil; session = nil; completed = false; wasPlaying = false
    }
}
