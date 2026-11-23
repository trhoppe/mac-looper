import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AM4InlineParameterValue: View {
    static var instructions: String {
        #if os(macOS)
        "Drag to adjust · Click a number to type · Double-click a knob to reset"
        #else
        "Drag to adjust · Double-tap a number to type · Double-tap a knob to reset"
        #endif
    }
    let definition: AM4ParameterDefinition
    let label: String
    let actual: AM4ParameterValue
    let identity: String
    var compact = false
    @Binding var editing: Bool
    let begin: () -> Void
    let apply: (Double) -> Void
    let cancel: () -> Void
    @State private var draft: AM4ParameterNumberDraft?
    @State private var invalid = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    private var font: Font { .system(compact ? .caption : .title3, design: .monospaced).weight(.semibold) }

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if draft != nil {
                    TextField(label, text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0; invalid = false }))
                        .textFieldStyle(.plain).font(font).multilineTextAlignment(.center)
                        .padding(.horizontal, 5).frame(maxWidth: .infinity, minHeight: 38)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(invalid ? Color.red : AM4Appearance.accent))
                        .focused($focused).accessibilityLabel("\(label) value")
                        .onSubmit(commit)
                        .onKeyPress(.escape) { abandon(); return .handled }
                        .onChange(of: focused) { _, value in if !value { commit() } }
                        .task {
                            // Let the field enter the native view hierarchy before
                            // asking it to become first responder.
                            await Task.yield()
                            guard draft != nil, !Task.isCancelled else { return }
                            focused = true
                        }
                        .background(AM4OutsideValueTap(active: draft != nil, outside: commit))
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation).submitLabel(.done)
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                if focused {
                                    Button("Cancel", action: abandon)
                                    Spacer()
                                    Button("Done", action: commit)
                                }
                            }
                        }
                        #endif
                } else {
                    #if os(macOS)
                    Button(action: start) { valueLabel }.buttonStyle(AM4ButtonStyle())
                        .accessibilityLabel("Edit \(label) value").help("Click to type a value")
                    #else
                    valueLabel.am4ControlHover().contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: start)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(label) value").accessibilityValue(actual.text)
                        .accessibilityHint("Double-tap the number to type. Drag the knob to adjust without a keyboard.")
                        .accessibilityAction(named: "Edit value") { start() }
                    #endif
                }
            }
            if invalid {
                Text("Enter \(definition.preview(0)) – \(definition.preview(1))")
                    .font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .onChange(of: identity) { _, _ in abandon() }
        .onChange(of: enabled) { _, value in if !value { abandon() } }
        .onDisappear(perform: abandon)
    }

    private var valueLabel: some View {
        Text(actual.text).font(font).lineLimit(1).minimumScaleFactor(0.55)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
    }
    private func start() {
        guard enabled, draft == nil else { return }
        begin()
        draft = AM4ParameterNumberDraft(definition: definition, position: actual.normalized, identity: identity)
        invalid = false; editing = true
    }
    private func commit() {
        guard var entry = draft else { return }
        guard enabled else { abandon(); return }
        let outcome = entry.commit(definition: definition, identity: identity)
        if outcome == .invalid { draft = entry; invalid = true; return }
        // Clear the draft before resigning focus so Enter + blur cannot apply twice.
        draft = nil; editing = false; focused = false; invalid = false
        switch outcome { case .apply(let value): apply(value); default: cancel() }
    }
    private func abandon() {
        guard draft != nil else { return }
        draft?.cancel(); draft = nil; editing = false; focused = false; invalid = false
        cancel()
    }
}

// Text fields do not necessarily lose focus when blank space or a knob is
// clicked. Observe outside taps without consuming the destination's event.
#if os(macOS)
private struct AM4OutsideValueTap: NSViewRepresentable {
    let active: Bool
    let outside: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.outside = outside; view.active = active }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.active = false }
    final class ObserverView: NSView {
        var outside: (() -> Void)?
        private var monitor: Any?
        var active = false {
            didSet {
                guard active != oldValue else { return }
                if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
                if active {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                        if let self, self.window != nil,
                           event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                            self.outside?()
                        }
                        return event
                    }
                }
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#else
private struct AM4OutsideValueTap: UIViewRepresentable {
    let active: Bool
    let outside: () -> Void
    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) { view.outside = outside; view.active = active }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.removeObserver() }
    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var outside: (() -> Void)?
        private var recognizer: UITapGestureRecognizer?
        var active = false { didSet { updateObserver() } }
        override func didMoveToWindow() { super.didMoveToWindow(); updateObserver() }
        private func updateObserver() {
            removeObserver()
            guard active, let window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false; tap.delegate = self
            window.addGestureRecognizer(tap); recognizer = tap
        }
        func removeObserver() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer); self.recognizer = nil }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !bounds.contains(touch.location(in: self))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc private func tapped() { outside?() }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    }
}
#endif
