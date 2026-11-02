import Foundation

/// Consecutive lines read across each row. Headings, blank separators and tabs
/// span the chart and flush a partial row before the following lines continue.
public enum ChartColumnPlan {
    public static let gutter = 28.0

    public static func columnWidth(availableWidth: Double, fontSize: Double, twoColumns: Bool = true) -> Double {
        let width = max(1, availableWidth.isFinite ? availableWidth : 600)
        let minimum = max(300, max(12, fontSize) * 0.6 * 36)
        return twoColumns && width >= minimum * 2 + gutter ? (width - gutter) / 2 : width
    }

    public static func rows(spanning: [Bool], availableWidth: Double, fontSize: Double, twoColumns: Bool = true) -> [[Int]] {
        let paired = columnWidth(availableWidth: availableWidth, fontSize: fontSize, twoColumns: twoColumns) < availableWidth
        var rows: [[Int]] = [], pending: Int?
        for index in spanning.indices {
            if !paired || spanning[index] {
                if let previous = pending { rows.append([previous]); pending = nil }
                rows.append([index])
            } else if let previous = pending {
                rows.append([previous, index]); pending = nil
            } else { pending = index }
        }
        if let previous = pending { rows.append([previous]) }
        return rows
    }
}
