import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The packaged Mac app carries a loose PNG; native Xcode targets use a catalog.
/// Load the loose resource explicitly rather than relying on catalog lookup.
struct WelcomeArtwork: View {
    #if os(macOS)
    private static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "LooperArtwork", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(named: "LooperArtwork")
    }()
    #endif
    var body: some View {
        #if os(macOS)
        if let image = Self.image { Image(nsImage: image).resizable().scaledToFit() }
        #else
        Image("LooperArtwork").resizable().scaledToFit()
        #endif
    }
}
