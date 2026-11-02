import SwiftUI
import JamCore
#if os(macOS)
import AppKit
#endif

/// Drag state stays inside this split; UserDefaults changes only at drag end.
/// Resizing does not change audio ownership, routing, or playback selection.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    let axis: Axis
    let side: PaneSizing.Side
    @Binding var size: Double
    let defaultSize: Double
    let minimumLeading: Double
    let minimumTrailing: Double
    let label: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @State private var dragOrigin: Double?
    @State private var preview: Double?
    #if os(macOS)
    private let thickness = 8.0
    #else
    private let thickness = 16.0
    #endif

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let sizes = resolved(total, preferred: preview ?? size)
            if axis == .horizontal {
                HStack(spacing: 0) {
                    leading().frame(width: sizes.leading).frame(maxHeight: .infinity).clipped()
                    handle(total: total, sizes: sizes).frame(width: sizes.divider)
                    trailing().frame(width: sizes.trailing).frame(maxHeight: .infinity).clipped()
                }
            } else {
                VStack(spacing: 0) {
                    leading().frame(height: sizes.leading).frame(maxWidth: .infinity).clipped()
                    handle(total: total, sizes: sizes).frame(height: sizes.divider)
                    trailing().frame(height: sizes.trailing).frame(maxWidth: .infinity).clipped()
                }
            }
        }
    }
    private func resolved(_ total: Double, preferred: Double) -> PaneSizing.Sizes {
        PaneSizing.resolve(total: total, preferred: preferred, side: side,
                           minimumLeading: minimumLeading, minimumTrailing: minimumTrailing, divider: thickness)
    }
    private func handle(total: Double, sizes: PaneSizing.Sizes) -> some View {
        ResizeDivider(axis: axis)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragOrigin ?? sizes.primary(side)
                    if dragOrigin == nil { dragOrigin = start }
                    let delta = axis == .horizontal ? drag.translation.width : drag.translation.height
                    preview = resolved(total, preferred: start + (side == .leading ? delta : -delta)).primary(side)
                }
                .onEnded { _ in
                    if let preview { size = resolved(total, preferred: preview).primary(side) }
                    preview = nil; dragOrigin = nil
                })
            .onTapGesture(count: 2) { size = defaultSize }
            .contextMenu { Button("Reset size") { size = defaultSize } }
            .accessibilityElement().accessibilityLabel(label)
            .accessibilityValue("\(Int(sizes.primary(side).rounded())) points")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 24.0 : -24.0
                size = resolved(total, preferred: sizes.primary(side) + delta).primary(side)
            }
            .help("Drag to resize. Double-click to reset.")
    }
}

private struct ResizeDivider: View {
    let axis: Axis
    @State private var hovering = false
    @State private var cursorPushed = false
    private let cyan = Color(red: 0.259, green: 0.788, blue: 0.961)
    var body: some View {
        ZStack {
            Rectangle().fill(hovering ? cyan.opacity(0.12) : .white.opacity(0.025))
            Rectangle().fill(.white.opacity(0.10))
                .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            Capsule().fill(hovering ? cyan : .white.opacity(0.28))
                .frame(width: axis == .horizontal ? 3 : 26, height: axis == .horizontal ? 26 : 3)
        }
        .onHover { value in
            hovering = value
            #if os(macOS)
            if value && !cursorPushed {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push(); cursorPushed = true
            } else if !value && cursorPushed { NSCursor.pop(); cursorPushed = false }
            #endif
        }
        .onDisappear {
            #if os(macOS)
            if cursorPushed { NSCursor.pop(); cursorPushed = false }
            #endif
        }
    }
}
