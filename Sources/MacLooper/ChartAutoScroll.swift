import SwiftUI
import JamCore
#if os(macOS)
import AppKit
typealias ChartAnchorBase = NSView
#else
import UIKit
typealias ChartAnchorBase = UIView
#endif

/// A noninteractive anchor inside the chart's existing ScrollView. Native offset
/// updates keep the timer out of SwiftUI's chart/layout and audio update paths.
final class ChartScrollAnchor: ChartAnchorBase {
    struct Viewport {
        let position: Double
        let distance: Double
        let interacting: Bool
    }
    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func viewport() -> Viewport? {
        guard window != nil, let scroll = enclosingScrollView, let document = scroll.documentView else { return nil }
        return Viewport(position: scroll.contentView.bounds.minY,
                        distance: max(0, document.frame.height - scroll.contentView.bounds.height), interacting: false)
    }
    func move(to position: Double) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: position))
        scroll.reflectScrolledClipView(clip)
    }
    #else
    private var scrollView: UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }
    func viewport() -> Viewport? {
        guard window != nil, let scroll = scrollView else { return nil }
        let insets = scroll.adjustedContentInset
        return Viewport(position: scroll.contentOffset.y + insets.top,
                        distance: max(0, scroll.contentSize.height + insets.top + insets.bottom - scroll.bounds.height),
                        interacting: scroll.isTracking || scroll.isDragging || scroll.isDecelerating)
    }
    func move(to position: Double) {
        guard let scroll = scrollView else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: position - scroll.adjustedContentInset.top), animated: false)
    }
    #endif
}

final class ChartScrollDriver {
    weak var anchor: ChartScrollAnchor?
    var active: Binding<Bool>
    var duration: Double
    private var timer: Timer?
    private var previousTime: TimeInterval = 0
    private var starting = true
    private var fractionalPosition: Double?
    init(active: Binding<Bool>, duration: Double) { self.active = active; self.duration = duration }
    func update(active: Binding<Bool>, duration: Double) {
        self.active = active; self.duration = duration
        guard active.wrappedValue else { stop(); return }
        guard timer == nil else { return }
        starting = true; fractionalPosition = nil; previousTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.002
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousTime
        previousTime = now
        guard active.wrappedValue else { stop(); return }
        guard let anchor, let viewport = anchor.viewport() else { return }
        guard viewport.distance > 0 else { finish(); return }
        // Touch scrolling remains usable; continue from the position the user chose.
        guard !viewport.interacting else { return }
        if starting {
            starting = false
            // Playing again at the end starts another pass through the chart.
            if viewport.position >= viewport.distance - 0.5 {
                fractionalPosition = 0; anchor.move(to: 0); return
            }
        }
        // Keep subpixel progress even if the native clip view rounds offsets.
        // A larger offset change indicates that the user scrolled manually.
        if fractionalPosition == nil || abs(viewport.position - fractionalPosition!) > 1 {
            fractionalPosition = viewport.position
        }
        let position = ChartScrollTiming.advance(position: fractionalPosition ?? viewport.position, distance: viewport.distance,
                                                elapsed: elapsed, duration: duration)
        fractionalPosition = position
        anchor.move(to: position)
        if position >= viewport.distance { finish() }
    }
    private func finish() { stop(); active.wrappedValue = false }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}

#if os(macOS)
struct ChartAutoScroll: NSViewRepresentable {
    @Binding var active: Bool
    let duration: Double
    func makeCoordinator() -> ChartScrollDriver { ChartScrollDriver(active: $active, duration: duration) }
    func makeNSView(context: Context) -> ChartScrollAnchor {
        let anchor = ChartScrollAnchor(); context.coordinator.anchor = anchor; return anchor
    }
    func updateNSView(_ view: ChartScrollAnchor, context: Context) {
        context.coordinator.update(active: $active, duration: duration)
    }
    static func dismantleNSView(_ view: ChartScrollAnchor, coordinator: ChartScrollDriver) { coordinator.stop() }
}
#else
struct ChartAutoScroll: UIViewRepresentable {
    @Binding var active: Bool
    let duration: Double
    func makeCoordinator() -> ChartScrollDriver { ChartScrollDriver(active: $active, duration: duration) }
    func makeUIView(context: Context) -> ChartScrollAnchor {
        let anchor = ChartScrollAnchor(); anchor.isUserInteractionEnabled = false
        context.coordinator.anchor = anchor; return anchor
    }
    func updateUIView(_ view: ChartScrollAnchor, context: Context) {
        context.coordinator.update(active: $active, duration: duration)
    }
    static func dismantleUIView(_ view: ChartScrollAnchor, coordinator: ChartScrollDriver) { coordinator.stop() }
}
#endif
