import Foundation

/// A snapshot of battery state for the vitals header.
struct BatteryInfo: Equatable, Sendable {
    enum State: Equatable, Sendable { case charging, discharging, charged, ac }

    let chargePercent: Int
    let state: State
    let timeRemainingMinutes: Int?   // nil when the estimate is unavailable/calculating

    /// e.g. "84% · 3:17" (discharging), "84% ⚡ 1:20" (charging), "100% ⚡" (charged/AC), "84%" (calculating).
    var displayText: String {
        let pct = "\(chargePercent)%"
        switch state {
        case .charging:
            return timeRemainingMinutes.map { "\(pct) ⚡ \(Self.time($0))" } ?? "\(pct) ⚡"
        case .discharging:
            return timeRemainingMinutes.map { "\(pct) · \(Self.time($0))" } ?? pct
        case .charged, .ac:
            return "\(pct) ⚡"
        }
    }

    private static func time(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Reads battery state, isolated behind a protocol so the sampler can use a fake.
protocol BatteryStatsProviding: Sendable {
    func read() -> BatteryInfo?   // nil when no battery is present
}
