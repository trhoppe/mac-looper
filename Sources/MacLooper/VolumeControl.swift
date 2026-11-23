import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct VolumeControl: View {
    @Binding var volume: Double
    let name: String
    @State private var showingSlider = false
    private var percent: Binding<Double> {
        Binding(get: { (volume * 100).rounded() }, set: { volume = min(100, max(0, $0)) / 100 })
    }
    var body: some View {
        HStack(spacing: 6) {
            Button { showingSlider.toggle() } label: {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }.buttonStyle(JamPlainButtonStyle()).help("Adjust \(name.lowercased()) volume")
                .accessibilityLabel("\(name) volume slider")
                .accessibilityValue(showingSlider ? "Shown" : "Hidden")
                #if os(macOS)
                .anchorPreference(key: VolumePopupKey.self, value: .bounds) { anchor in
                    showingSlider ? VolumePopupRequest(anchor: anchor, content: AnyView(slider), close: { showingSlider = false }) : nil
                }
                #else
                .popover(isPresented: $showingSlider, arrowEdge: .top) {
                    slider.presentationCompactAdaptation(.popover)
                }
                #endif
            VolumeNumberField(value: percent, label: "\(name) volume percentage")
                .jamNumberField(width: 36, fontSize: 12, horizontalPadding: 4)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }.fixedSize()
    }
    private var slider: some View {
        Slider(value: $volume, in: 0...1).hoverHighlight()
            .accessibilityLabel("\(name) volume")
            .padding(.horizontal, 16).padding(.vertical, 12).frame(width: 236)
            .background(Color(red: 0.075, green: 0.085, blue: 0.10))
    }
}

// Keep partial input local. Typing replaces the selected percentage rather than
// having a formatter rewrite the number or caret after every keystroke.
private struct VolumeNumberField {
    @Binding var value: Double
    let label: String
    func accept(_ text: String, finishing: Bool) -> Double? {
        guard let number = Double(text), number.isFinite else { return nil }
        guard finishing || (0...100).contains(number) else { return nil }
        return min(100, max(0, number.rounded()))
    }
    var text: String { String(Int(value.rounded())) }
}

#if os(macOS)
extension VolumeNumberField: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NumberField {
        let field = NumberField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.alignment = .center; field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.delegate = context.coordinator; field.setAccessibilityLabel(label)
        return field
    }
    func updateNSView(_ field: NumberField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil { field.stringValue = text }
    }
    final class NumberField: NSTextField {
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: VolumeNumberField
        init(_ parent: VolumeNumberField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            DispatchQueue.main.async { [weak field] in field?.currentEditor()?.selectAll(nil) }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let value = parent.accept(field.stringValue, finishing: false) else { return }
            parent.value = value
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(field)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            if selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)) {
                let delta = selector == #selector(NSResponder.moveUp(_:)) ? 1.0 : -1.0
                parent.value = min(100, max(0, (parent.accept(field.stringValue, finishing: true) ?? parent.value) + delta))
                field.stringValue = parent.text; textView.selectAll(nil)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(field); field.window?.makeFirstResponder(nil); return true
            }
            return false
        }
        private func finish(_ field: NSTextField) {
            if let value = parent.accept(field.stringValue, finishing: true) { parent.value = value }
            field.stringValue = parent.text
        }
    }
}

struct VolumePopupRequest {
    let anchor: Anchor<CGRect>
    let content: AnyView
    let close: () -> Void
}
struct VolumePopupKey: PreferenceKey {
    static var defaultValue: VolumePopupRequest? { nil }
    static func reduce(value: inout VolumePopupRequest?, nextValue: () -> VolumePopupRequest?) {
        if let next = nextValue() { value = next }
    }
}
struct WindowVolumePopup: View {
    let request: VolumePopupRequest
    var body: some View {
        GeometryReader { geo in
            let trigger = geo[request.anchor]
            let width = min(236.0, max(0, geo.size.width - 16))
            let x = min(max(8, trigger.midX - width / 2), max(8, geo.size.width - width - 8))
            let y = min(trigger.maxY + 4, max(8, geo.size.height - 64))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: request.close)
                JamPopupSurface(edge: .top, pointer: trigger.midX - x) { request.content }
                    .fixedSize().offset(x: x, y: y)
                Button("Close volume slider", action: request.close).keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
    }
}
#else
extension VolumeNumberField: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> NumberField {
        let field = NumberField()
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.textAlignment = .center; field.textColor = .label
        field.keyboardType = .numberPad; field.delegate = context.coordinator
        field.accessibilityLabel = label
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.step = { [weak coordinator = context.coordinator, weak field] delta in
            guard let field else { return }
            coordinator?.step(field, delta: delta)
        }
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        toolbar.items = [.flexibleSpace(), UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.done))]
        field.inputAccessoryView = toolbar
        context.coordinator.field = field
        return field
    }
    func updateUIView(_ field: NumberField, context: Context) {
        context.coordinator.parent = self
        if !field.isFirstResponder { field.text = text }
    }
    final class NumberField: UITextField {
        var step: ((Double) -> Void)?
        override var keyCommands: [UIKeyCommand]? {
            [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow].map {
                let command = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(arrow(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        @objc private func arrow(_ command: UIKeyCommand) { step?(command.input == UIKeyCommand.inputUpArrow ? 1 : -1) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            DispatchQueue.main.async { [weak self] in self?.selectAll(nil) }
        }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: VolumeNumberField
        weak var field: NumberField?
        init(_ parent: VolumeNumberField) { self.parent = parent }
        func textFieldDidBeginEditing(_ field: UITextField) {
            DispatchQueue.main.async { field.selectAll(nil) }
        }
        @objc func changed(_ field: UITextField) {
            if let value = parent.accept(field.text ?? "", finishing: false) { parent.value = value }
        }
        func textFieldDidEndEditing(_ field: UITextField) { finish(field) }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { field.resignFirstResponder(); return true }
        @objc func done() { field?.resignFirstResponder() }
        func step(_ field: UITextField, delta: Double) {
            parent.value = min(100, max(0, (parent.accept(field.text ?? "", finishing: true) ?? parent.value) + delta))
            field.text = parent.text; field.selectAll(nil)
        }
        private func finish(_ field: UITextField) {
            if let value = parent.accept(field.text ?? "", finishing: true) { parent.value = value }
            field.text = parent.text
        }
    }
}
#endif
