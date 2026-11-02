import Foundation

/// Chooses a single reading-order split using measured block heights. Width is
/// relative to typography, so either a wider chart or smaller text enables flow.
public enum ChartColumnPlan {
    public enum Break: Sendable { case normal, section, blank }
    public static let gutter = 28.0

    public static func columnWidth(availableWidth: Double, fontSize: Double) -> Double {
        let width = max(1, availableWidth.isFinite ? availableWidth : 600)
        let minimum = max(300, max(12, fontSize) * 0.6 * 36)
        return width >= minimum * 2 + gutter ? (width - gutter) / 2 : width
    }

    public static func split(heights: [Double], breaks: [Break], availableWidth: Double, fontSize: Double) -> Int? {
        guard heights.count > 1, heights.count == breaks.count,
              columnWidth(availableWidth: availableWidth, fontSize: fontSize) < availableWidth else { return nil }
        let spacing = fontSize * 0.2
        let total = heights.reduce(0, +) + Double(heights.count - 1) * spacing
        var prefix = 0.0
        var previousContent = Break.normal
        var candidates: [(index: Int, height: Double, section: Bool)] = []
        for index in 1..<heights.count {
            prefix += heights[index - 1] + (index > 1 ? spacing : 0)
            if breaks[index - 1] != .blank { previousContent = breaks[index - 1] }
            // Keep a heading with its first content, even with intervening blanks.
            // Do not begin the second column on a blank row.
            guard previousContent != .section, breaks[index] != .blank else { continue }
            let height = max(prefix, total - prefix - spacing)
            candidates.append((index, height, breaks[index] == .section || breaks[index - 1] == .blank))
        }
        guard let best = candidates.min(by: { $0.height < $1.height }) else { return nil }
        // Prefer a stanza/section boundary unless it makes the chart much taller.
        return candidates.filter { $0.section && $0.height <= best.height * 1.15 }
            .min(by: { $0.height < $1.height })?.index ?? best.index
    }
}
