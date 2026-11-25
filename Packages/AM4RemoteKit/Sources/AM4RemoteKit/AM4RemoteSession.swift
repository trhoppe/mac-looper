import JamDesignKit
import SwiftUI

/// Publishes presentation changes only. Frequent MIDI state updates are observed
/// inside the remote screen, not by the jam workspace or its chord chart.
@MainActor public final class AM4RemoteSession: ObservableObject {
    @Published public private(set) var isPresented = false
    let connection = AM4Connection()
    private let connectAutomatically: Bool
    private var applicationActive = true
    public func setApplicationActive(_ active: Bool) {
        applicationActive = active; connection.pollingEnabled = active && isPresented
        if active && isPresented && connectAutomatically { connection.start() }
    }
    public init(connectAutomatically: Bool = true) { self.connectAutomatically = connectAutomatically }
    private static let preloadCatalogs = Task.detached(priority: .utility) {
        _ = AM4AmpCatalog.shared
        _ = AM4EffectsCatalog.shared
        _ = AM4AmpLibrary.shared
        _ = AM4EffectsLibrary.shared
    }

    public func present() {
        _ = Self.preloadCatalogs
        connection.pollingEnabled = applicationActive
        isPresented = true
        if connectAutomatically && applicationActive { connection.start() }
    }
    public func dismiss() {
        // Do not disconnect: a command already sent must finish its verification.
        connection.pollingEnabled = false
        connection.clearPageSubscriptions()
        isPresented = false
    }
    public func stop() { connection.stop() }
}

/// Full-app overlay, like the song editor. Its Close control is always outside
/// the remote's preset navigation and block editors.
@MainActor public struct AM4RemoteScreen: View {
    @ObservedObject private var session: AM4RemoteSession
    private let embedded: Bool
    public init(session: AM4RemoteSession, embedded: Bool = false) { self.session = session; self.embedded = embedded }
    public var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                JamScreenHeader("AM4 Remote", icon: "slider.horizontal.3", closeOnEscape: false, close: { session.dismiss() })
                Divider()
            }
            AM4RemoteView(midi: session.connection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JamDesign.ground)
        .foregroundStyle(JamDesign.text).tint(JamDesign.accent)
        .preferredColorScheme(.dark)
    }
}
