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
    public func present() {
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
    public init(session: AM4RemoteSession) { self.session = session }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AM4 Remote", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Button("Close") { session.dismiss() }.buttonStyle(AM4NativeButtonStyle())
                    .accessibilityLabel("Close AM4 Remote")
            }.padding(18)
            Divider()
            AM4RemoteView(midi: session.connection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.065, green: 0.075, blue: 0.085))
        .preferredColorScheme(.dark)
    }
}
