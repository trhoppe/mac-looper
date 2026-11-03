import SwiftUI

// Keep pointer feedback local to each item, without updating the browser or app.
private struct HoverHighlight: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(enabled && hovering ? 0.075 : 0))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(enabled && hovering ? 0.14 : 0)) }
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: enabled && hovering)
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

// Paint the entire row, including its padding, over the native selection.
// Selected and hovered rows use one fill, so hovering a selection never stacks.
private struct BrowserRowHighlight: ViewModifier {
    let selected: Bool
    let background: Color
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(selected || hovering ? Color(white: 0.20) : background)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: selected || hovering)
    }
}

extension View {
    func browserRowHighlight(selected: Bool, background: Color = Color(red: 0.065, green: 0.075, blue: 0.085)) -> some View {
        modifier(BrowserRowHighlight(selected: selected, background: background))
    }
}

// Keep native button behavior and sizing; add pointer feedback to its full bounds.
struct JamButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if prominent { Button(configuration).buttonStyle(.borderedProminent) }
            else { Button(configuration).buttonStyle(.bordered) }
        }.hoverHighlight()
    }
}

struct JamPlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
            .hoverHighlight()
    }
}
