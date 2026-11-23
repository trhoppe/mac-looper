#if os(macOS)
import AppKit
import SwiftUI

/// Keep the native menu, with its opening point independent of the label.
struct MacMoreMenuButton: View {
    let compact: Bool
    let openRemote: () -> Void
    let openChords: () -> Void
    let openScales: () -> Void
    @State private var presenter = MoreMenuPresenter()
    @State private var presenting = false

    var body: some View {
        Button {
            presenting = true
            DispatchQueue.main.async {
                presenter.show(actions: [openRemote, openChords, openScales])
                presenting = false
            }
        } label: {
            HStack(spacing: compact ? 5 : 8) {
                Image(systemName: "chevron.down").font(.caption)
                Text("More")
            }.font(compact ? .callout : .body)
                .foregroundStyle(presenting ? Color(red: 0.259, green: 0.788, blue: 0.961) : Color.secondary)
                .padding(.horizontal, compact ? 4 : 9).padding(.vertical, 6)
        }.buttonStyle(JamPlainButtonStyle()).fixedSize().accessibilityLabel("More")
            .background(MoreMenuAnchor(presenter: presenter))
    }
}

private final class MoreMenuPresenter: NSObject {
    weak var anchor: NSView?
    private var actions: [() -> Void] = []

    func show(actions: [() -> Void]) {
        guard let anchor, anchor.window != nil else { return }
        self.actions = actions
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries = [("AM4 Remote", "slider.horizontal.3"), ("Chord Library", "guitars"), ("Scales", "music.note.list")]
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: entry.0, action: #selector(selectItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: nil)
            menu.addItem(item)
        }
        let y = anchor.isFlipped ? anchor.bounds.maxY + 8 : anchor.bounds.minY - 8
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: y), in: anchor)
        self.actions = []
    }

    @objc private func selectItem(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        let action = actions[item.tag]
        // Present the full-app screen after native menu tracking has ended.
        DispatchQueue.main.async { action() }
    }
}

private struct MoreMenuAnchor: NSViewRepresentable {
    let presenter: MoreMenuPresenter
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        presenter.anchor = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { presenter.anchor = nsView }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
