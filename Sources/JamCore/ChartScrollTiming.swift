import Foundation

/// The speed covers the chart's full scrollable distance in one song length.
/// Pausing and resuming from partway down preserves that same reading speed.
public enum ChartScrollTiming {
    public static func duration(_ source: String?) -> Double {
        let parts = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return 180 }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.dropFirst().allSatisfy({ $0 < 60 }) else { return 180 }
        let seconds = values.reduce(0) { $0 * 60 + $1 }
        return seconds.isFinite && seconds > 0 ? seconds : 180
    }

    public static func advance(position: Double, distance: Double, elapsed: Double, duration: Double) -> Double {
        guard distance.isFinite, distance > 0 else { return 0 }
        guard position.isFinite, elapsed.isFinite, elapsed >= 0, duration.isFinite, duration > 0 else {
            return min(distance, max(0, position.isFinite ? position : 0))
        }
        return min(distance, max(0, position) + distance * elapsed / duration)
    }
}
