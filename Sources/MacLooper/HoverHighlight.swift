import SwiftUI

// Keep pointer feedback local to each item, without updating the browser or app.
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(hovering ? 0.075 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
