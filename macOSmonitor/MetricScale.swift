import Foundation

/// Decides the y-range a metric graph draws against. Pure, so it can be tested
/// without instantiating a view.
enum MetricScale {
    /// Minimum ceiling for autoscaled rate graphs. Without a floor, an idle
    /// network amplifies byte-level noise into a dramatic, meaningless mountain range.
    static let rateFloor: Double = 100_000   // 100 KB/s

    /// A bounded metric: CPU is 0...100, memory is 0...total.
    static func fixed(_ upper: Double) -> ClosedRange<Double> {
        0...max(upper, 1)
    }

    /// An unbounded rate metric. All supplied series share one axis so they stay
    /// visually comparable; the floor keeps idle noise flat.
    static func autoscaled(_ series: [MetricHistory],
                           floor: Double = rateFloor) -> ClosedRange<Double> {
        let peak = series.map(\.peak).max() ?? 0
        return 0...max(peak, floor)
    }
}
