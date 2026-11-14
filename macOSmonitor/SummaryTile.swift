import Foundation

/// What one of the Summary's bottom-row tiles says: a headline value, a detail line, and how
/// full its meter is. Pure, so every rule is testable without a view.
///
/// Network and Disk rates have no natural maximum, so their meters are measured against the
/// busiest second in the graph window, and the tile says so ("Peak 40 MB/s"): a labelled
/// scale, not a utilisation reading in disguise.
struct SummaryTile: Equatable, Sendable {
    let value: String
    let detail: String
    /// 0...1.
    let fraction: Double
    /// What a full meter means, when that isn't obvious from the value.
    var scale: String? = nil

    nonisolated static func network(_ vitals: SystemVitals?, inHistory: MetricHistory,
                                     outHistory: MetricHistory) -> SummaryTile {
        guard let vitals else { return SummaryTile(value: "—", detail: "", fraction: 0) }
        let rateIn = vitals.networkInBytesPerSec, rateOut = vitals.networkOutBytesPerSec
        return rateTile(total: rateIn + rateOut,
                        detail: "↓ \(SystemVitals.rate(rateIn)) · ↑ \(SystemVitals.rate(rateOut))",
                        a: inHistory, b: outHistory)
    }

    nonisolated static func disk(_ vitals: SystemVitals?, readHistory: MetricHistory,
                                 writeHistory: MetricHistory) -> SummaryTile {
        guard let vitals else { return SummaryTile(value: "—", detail: "", fraction: 0) }
        let read = vitals.diskReadBytesPerSec, write = vitals.diskWriteBytesPerSec
        return rateTile(total: read + write,
                        detail: "R \(SystemVitals.rate(read)) · W \(SystemVitals.rate(write))",
                        a: readHistory, b: writeHistory)
    }

    nonisolated static func battery(_ battery: BatteryInfo) -> SummaryTile {
        let detail: String
        switch battery.state {
        case .discharging:
            detail = battery.timeRemainingMinutes.map { "\(clock($0)) remaining" } ?? "Calculating…"
        case .charging:
            detail = battery.timeRemainingMinutes.map { "Charging · full in \(clock($0))" } ?? "Charging"
        case .charged:
            detail = "Charged"
        case .ac:
            detail = "On power, not charging"
        }
        return SummaryTile(value: "\(battery.chargePercent)%", detail: detail,
                           fraction: Double(battery.chargePercent) / 100)
    }

    /// The four thermal-pressure levels fill the meter a quarter at a time.
    nonisolated static func thermal(_ vitals: SystemVitals?, cpuCelsius: Double?) -> SummaryTile {
        guard let vitals else { return SummaryTile(value: "—", detail: "", fraction: 0) }
        let levels = ["Nominal", "Fair", "Serious", "Critical"]
        let level = levels.firstIndex(of: vitals.thermalState).map { Double($0 + 1) / 4 } ?? 0
        let detail = cpuCelsius.map { "CPU \(ThermalReading.text($0))" } ?? "Thermal pressure"
        return SummaryTile(value: vitals.thermalState, detail: detail, fraction: level)
    }

    /// A rate tile: the meter is `total` against the busiest second of `a + b` in the window.
    private nonisolated static func rateTile(total: Double, detail: String,
                                             a: MetricHistory, b: MetricHistory) -> SummaryTile {
        let peak = zip(a.values, b.values).map { $0 + $1 }.max() ?? 0
        return SummaryTile(value: SystemVitals.rate(total), detail: detail,
                           fraction: peak > 0 ? min(total / peak, 1) : 0,
                           scale: peak > 0 ? "Peak \(SystemVitals.rate(peak))" : nil)
    }

    private nonisolated static func clock(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
