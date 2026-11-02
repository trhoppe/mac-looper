import SwiftUI
import JamCore
#if os(macOS)
import AppKit
private typealias SourceFont = NSFont
private typealias SourceColor = NSColor
#else
import UIKit
private typealias SourceFont = UIFont
private typealias SourceColor = UIColor
#endif

@MainActor private enum SourceHighlight {
    static let font = SourceFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    static let text = SourceColor(white: 0.87, alpha: 1)
    static let background = SourceColor(white: 0.075, alpha: 1)
    static var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: text] }
    static func apply(to storage: NSTextStorage) {
        let selection = ChordProSyntax.spans(in: storage.string)
        storage.beginEditing()
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        for span in selection {
            if span.style == .chord {
                storage.addAttribute(.foregroundColor, value: SourceColor(red: 0.259, green: 0.788, blue: 0.961, alpha: 1), range: span.range)
            } else {
                storage.addAttributes([.foregroundColor: SourceColor(white: 0.65, alpha: 1),
                                       .font: SourceFont.monospacedSystemFont(ofSize: 16, weight: .bold)], range: span.range)
            }
        }
        storage.endEditing()
    }
}

#if os(macOS)
struct ChordProTextEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.delegate = context.coordinator
        view.isRichText = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = SourceHighlight.font; view.textColor = SourceHighlight.text
        view.backgroundColor = SourceHighlight.background
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("ChordPro source")
        view.string = text
        scroll.documentView = view
        context.coordinator.highlight(view)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = context.environment.isEnabled
        guard view.string != text else { return }
        view.string = text; context.coordinator.highlight(view)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChordProTextEditor
        private var pending: Task<Void, Never>?
        init(_ parent: ChordProTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            pending?.cancel()
            pending = Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, let view, !view.hasMarkedText() else { return }
                self.highlight(view)
            }
        }
        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            SourceHighlight.apply(to: storage); view.typingAttributes = SourceHighlight.attributes
        }
        deinit { pending?.cancel() }
    }
}
#else
struct ChordProTextEditor: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = SourceHighlight.font; view.textColor = SourceHighlight.text
        view.backgroundColor = SourceHighlight.background
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.alwaysBounceVertical = true; view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no; view.autocapitalizationType = .none
        view.spellCheckingType = .no; view.smartQuotesType = .no; view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityLabel = "ChordPro source"
        view.text = text; context.coordinator.highlight(view)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = context.environment.isEnabled
        guard view.text != text else { return }
        view.text = text; context.coordinator.highlight(view)
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChordProTextEditor
        private var pending: Task<Void, Never>?
        init(_ parent: ChordProTextEditor) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            pending?.cancel()
            pending = Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, let view, view.markedTextRange == nil else { return }
                self.highlight(view)
            }
        }
        func highlight(_ view: UITextView) {
            SourceHighlight.apply(to: view.textStorage); view.typingAttributes = SourceHighlight.attributes
        }
        deinit { pending?.cancel() }
    }
}
#endif
