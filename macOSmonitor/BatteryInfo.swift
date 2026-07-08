import Foundation
import IOKit.ps

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

struct BatteryStats: BatteryStatsProviding {
    func read() -> BatteryInfo? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        guard let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue()
                as? [String: Any]
        else { return nil }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = maxCapacity > 0
            ? Int((Double(current) / Double(maxCapacity) * 100).rounded())
            : current
        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let powerState = desc[kIOPSPowerSourceStateKey] as? String

        let state: BatteryInfo.State
        let minutes: Int?
        if isCharging {
            state = .charging
            let t = desc[kIOPSTimeToFullChargeKey] as? Int ?? -1
            minutes = t > 0 ? t : nil
        } else if powerState == kIOPSACPowerValue {
            state = percent >= 100 ? .charged : .ac
            minutes = nil
        } else {
            state = .discharging
            let t = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
            minutes = t > 0 ? t : nil
        }
        return BatteryInfo(chargePercent: percent, state: state, timeRemainingMinutes: minutes)
    }
}
