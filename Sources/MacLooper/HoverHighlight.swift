import SwiftUI

private struct JamBrowserBoundsKey: EnvironmentKey {
    static let defaultValue = CGRect(x: 0, y: 60, width: 800, height: 640)
}
extension EnvironmentValues {
    var jamBrowserBounds: CGRect {
        get { self[JamBrowserBoundsKey.self] }
        set { self[JamBrowserBoundsKey.self] = newValue }
    }
}

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

// One compact, square-cornered control treatment on Mac and iPad.
struct JamButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(JamFilledButtonStyle(prominent: prominent))
    }
}

private struct JamFilledButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.primary)
            .padding(.horizontal, size == .large ? 12 : 10)
            .padding(.vertical, size == .large ? 7 : 5)
            .background(Color(white: configuration.isPressed ? 0.22 : prominent ? 0.34 : 0.29), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.10)) }
            .opacity(enabled ? 1 : 0.4)
            .hoverHighlight()
    }
}

extension View {
    func jamNumberField(width: CGFloat, height: CGFloat = 28, fontSize: CGFloat = 14) -> some View {
        self.font(.system(size: fontSize, weight: .medium).monospacedDigit())
            .padding(.horizontal, 6).frame(width: width, height: height)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)) }
            .hoverHighlight()
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

#if os(macOS)
enum JamPopupEdge { case top, leading }

private struct JamPopupShape: Shape {
    let edge: JamPopupEdge
    let pointer: CGFloat
    func path(in rect: CGRect) -> Path {
        let left: CGFloat = edge == .leading ? 8 : 0
        let top: CGFloat = edge == .top ? 8 : 0
        let right = rect.width, bottom = rect.height, radius: CGFloat = 8
        let tip = min(max(pointer, 20), (edge == .top ? right : bottom) - 20)
        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: top))
        if edge == .top {
            path.addLine(to: CGPoint(x: tip - 8, y: top))
            path.addLine(to: CGPoint(x: tip, y: 0))
            path.addLine(to: CGPoint(x: tip + 8, y: top))
        }
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + radius), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - radius), control: CGPoint(x: left, y: bottom))
        if edge == .leading {
            path.addLine(to: CGPoint(x: left, y: tip + 8))
            path.addLine(to: CGPoint(x: 0, y: tip))
            path.addLine(to: CGPoint(x: left, y: tip - 8))
        }
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
}

struct JamPopupSurface<Content: View>: View {
    let edge: JamPopupEdge
    let pointer: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        let shape = JamPopupShape(edge: edge, pointer: pointer)
        content().clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(edge == .top ? .top : .leading, 8)
            .background(shape.fill(Color(red: 0.065, green: 0.075, blue: 0.085)))
            .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 1) }
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}

// Carry the trigger's anchor to the window root, beyond any pane's clipping.
struct AudioBrowserPopupRequest {
    let anchor: Anchor<CGRect>
    let content: AnyView
    let close: () -> Void
}
struct AudioBrowserPopupKey: PreferenceKey {
    static var defaultValue: AudioBrowserPopupRequest? { nil }
    static func reduce(value: inout AudioBrowserPopupRequest?, nextValue: () -> AudioBrowserPopupRequest?) {
        if let next = nextValue() { value = next }
    }
}
struct SettingsPopupAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

struct WindowSettingsPopup<Content: View>: View {
    let anchor: Anchor<CGRect>
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geo in
            let trigger = geo[anchor]
            let width = min(430, max(0, geo.size.width - 16))
            let y = min(trigger.maxY + 6, max(8, geo.size.height - 48))
            let height = max(0, geo.size.height * 0.9 - y)
            let x = min(max(8, trigger.midX - width / 2), max(8, geo.size.width - width - 8))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: close)
                JamPopupSurface(edge: .top, pointer: trigger.midX - x, content: content)
                    .frame(width: width, height: height).offset(x: x, y: y)
                Button("Close Settings", action: close).keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
    }
}

struct WindowAudioBrowserPopup: View {
    let request: AudioBrowserPopupRequest
    var top: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            let anchor = geo[request.anchor]
            let opensRight = anchor.maxX + 356 <= geo.size.width - 8
            let width = min(opensRight ? 348 : 340, max(0, geo.size.width - 16))
            let y = opensRight ? max(8, top + 4) : anchor.maxY + 6
            let height = max(0, geo.size.height * 0.9 - y)
            let preferredX = opensRight ? anchor.maxX + 8 : anchor.midX - width / 2
            let x = min(max(8, preferredX), max(8, geo.size.width - width - 8))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: request.close)
                JamPopupSurface(edge: opensRight ? .leading : .top,
                                pointer: opensRight ? anchor.midY - y : anchor.midX - x) { request.content }
                    .frame(width: width, height: height).offset(x: x, y: y)
                Button("Close Audio Files", action: request.close).keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
    }
}
#endif
