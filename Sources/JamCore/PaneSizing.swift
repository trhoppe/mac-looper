import Foundation

public enum PaneSizing {
    public enum Side: Sendable { case leading, trailing }
    public struct Sizes: Equatable, Sendable {
        public let leading: Double
        public let trailing: Double
        public let divider: Double
        public func primary(_ side: Side) -> Double { side == .leading ? leading : trailing }
    }
    /// Clamp against both panes. Small windows shrink the minima proportionally
    /// without overwriting the user's saved size for a larger window/orientation.
    public static func resolve(total: Double, preferred: Double, side: Side,
                               minimumLeading: Double, minimumTrailing: Double, divider: Double) -> Sizes {
        let total = total.isFinite ? max(0, total) : 0
        let divider = min(total, divider.isFinite ? max(0, divider) : 0)
        let available = total - divider
        let a = minimumLeading.isFinite ? max(0, minimumLeading) : 0
        let b = minimumTrailing.isFinite ? max(0, minimumTrailing) : 0
        let leading: Double
        if available < a + b {
            leading = a + b > 0 ? available * a / (a + b) : available / 2
        } else {
            let preferred = preferred.isFinite ? preferred : available / 2
            leading = min(available - b, max(a, side == .leading ? preferred : available - preferred))
        }
        return Sizes(leading: leading, trailing: max(0, available - leading), divider: divider)
    }
}
