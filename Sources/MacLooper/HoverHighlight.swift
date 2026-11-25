import JamDesignKit
import SwiftUI

// Keep pointer feedback local to each item, without updating the browser or app.
extension View {
    func hoverHighlight() -> some View { jamFeedback() }
}

// Paint the entire row, including its padding, over the native selection.
// Selected and hovered rows use one fill, so hovering a selection never stacks.
private struct BrowserRowHighlight: ViewModifier {
    let selected: Bool
    let background: Color
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(selected || hovering ? JamDesign.selection : background)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: selected || hovering)
    }
}

extension View {
    func browserRowHighlight(selected: Bool, background: Color = JamDesign.ground) -> some View {
        modifier(BrowserRowHighlight(selected: selected, background: background))
    }
}

// One compact, square-cornered control treatment on Mac and iPad.
struct JamButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(JamControlStyle(active: prominent))
    }
}


extension View {
    func jamNumberField(width: CGFloat, height: CGFloat = 28, fontSize: CGFloat = 14, horizontalPadding: CGFloat = 6) -> some View {
        self.font(.system(size: fontSize, weight: .medium).monospacedDigit())
            .padding(.horizontal, horizontalPadding).frame(width: width, height: height)
            .background(JamDesign.control, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(JamDesign.border) }
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

enum JamPopupEdge { case top, bottom, leading }

private struct JamPopupShape: Shape {
    let edge: JamPopupEdge
    let pointer: CGFloat
    func path(in rect: CGRect) -> Path {
        let left: CGFloat = edge == .leading ? 8 : 0
        let top: CGFloat = edge == .top ? 8 : 0
        let right = rect.width, bottom = rect.height - (edge == .bottom ? 8 : 0), radius: CGFloat = JamDesign.radius
        let tip = min(max(pointer, 20), (edge == .leading ? bottom : right) - 20)
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
        if edge == .bottom {
            path.addLine(to: CGPoint(x: tip + 8, y: bottom))
            path.addLine(to: CGPoint(x: tip, y: rect.height))
            path.addLine(to: CGPoint(x: tip - 8, y: bottom))
        }
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
        content().clipShape(RoundedRectangle(cornerRadius: JamDesign.radius))
            .padding(edge == .top ? .top : edge == .bottom ? .bottom : .leading, 8)
            .background(shape.fill(JamDesign.card))
            .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 1) }
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}

// One request and window-level presenter for Songs, More, Settings, and Audio Files.
struct JamDropdownRequest {
    let anchor: Anchor<CGRect>
    let title: String
    let content: AnyView
    let close: () -> Void
    var width: CGFloat = 340
    var height: CGFloat? = nil
    var prefersAbove = false
    var alignLeading = false
    var opensBeside = false
}
struct JamDropdownPopupKey: PreferenceKey {
    static var defaultValue: JamDropdownRequest? { nil }
    static func reduce(value: inout JamDropdownRequest?, nextValue: () -> JamDropdownRequest?) {
        if let next = nextValue() { value = next }
    }
}
struct JamDropdownPopup: View {
    let request: JamDropdownRequest
    var top: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button("Done", action: request.close).padding(12) }
                    request.content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.background(JamDesign.card).accessibilityAddTraits(.isModal)
            } else {
                anchoredPopup(in: geo)
            }
            #else
            anchoredPopup(in: geo)
            #endif
        }
    }
    private func anchoredPopup(in geo: GeometryProxy) -> some View {
        let anchor = geo[request.anchor]
        let opensRight = request.opensBeside && anchor.maxX + request.width + 16 <= geo.size.width - 8
        let width = min(request.width + (opensRight ? 8 : 0), max(0, geo.size.width - 16))
        let belowY = anchor.maxY + 6
        let ceiling = max(8, top + 4), floor = geo.size.height * 0.9
        let aboveBottom = min(anchor.minY - 6, floor)
        let aboveAvailable = max(0, aboveBottom - ceiling), belowAvailable = max(0, floor - belowY)
        let opensAbove = request.prefersAbove && !opensRight && belowAvailable < (request.height ?? aboveAvailable) && aboveAvailable > belowAvailable
        let available = opensAbove ? aboveAvailable : opensRight ? max(0, floor - ceiling) : belowAvailable
        let height = min(request.height ?? available, available)
        let y = opensAbove ? aboveBottom - height : opensRight ? ceiling : belowY
        let preferredX = opensRight ? anchor.maxX + 8 : request.alignLeading ? anchor.minX : anchor.midX - width / 2
        let x = min(max(8, preferredX), max(8, geo.size.width - width - 8))
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: request.close)
            JamPopupSurface(edge: opensRight ? .leading : opensAbove ? .bottom : .top,
                            pointer: opensRight ? anchor.midY - y : anchor.midX - x) { request.content }
                .frame(width: width, height: height).offset(x: x, y: y)
            Button("Close " + request.title, action: request.close).keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }
}
