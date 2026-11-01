#if DEBUG
import AppKit

// Render only this app's own view tree for layout review; no screen capture permission.
@MainActor enum AppPreview {
    static func write(to url: URL, files: AudioFilePlayerModel) async throws {
        for _ in 0..<100 where files.scanning { try await Task.sleep(for: .milliseconds(30)) }
        if let first = files.tracks.first {
            files.select(first)
            for _ in 0..<100 where files.loading { try await Task.sleep(for: .milliseconds(30)) }
        }
        try await Task.sleep(for: .milliseconds(250))
        guard let view = NSApplication.shared.windows.first(where: { $0.title == "Mac Looper" })?.contentView else {
            throw AudioFailure(message: "Preview window unavailable.")
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AudioFailure(message: "Preview rendering unavailable.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AudioFailure(message: "Preview PNG unavailable.") }
        try data.write(to: url)
    }
}
#endif
