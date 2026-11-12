import Foundation
import Observation

/// Owns the Battery panel's data: live state, health, and the recorded 24-hour history.
/// Its loop runs for the app's lifetime (owned by `ContentView`), so history keeps
/// recording while other surfaces are shown. On a Mac without a battery it records nothing.
@MainActor
@Observable
final class BatteryModel {
    private(set) var info: BatteryInfo?
    private(set) var health: BatteryHealth?
    private(set) var history: BatteryHistory

    private let stats: any BatteryStatsProviding
    private let healthProvider: any BatteryHealthProviding
    private let store: any BatteryHistoryStoring
    private let interval: Duration
    private let now: @Sendable () -> Date

    init(stats: any BatteryStatsProviding = BatteryStats(),
         healthProvider: any BatteryHealthProviding = SmartBattery(),
         store: any BatteryHistoryStoring = BatteryHistoryFile(),
         interval: Duration = .seconds(2),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.stats = stats
        self.healthProvider = healthProvider
        self.store = store
        self.interval = interval
        self.now = now
        history = store.load()
    }

    func refreshOnce() {
        info = stats.read()
        health = healthProvider.read()
        guard let info else { return }
        let sample = BatteryHistory.Sample(date: now(), percent: info.chargePercent,
                                           onPower: info.state != .discharging)
        if history.record(sample) { store.save(history) }
    }

    func run() async {
        while !Task.isCancelled {
            refreshOnce()
            try? await Task.sleep(for: interval)
        }
    }

    /// The panel's status line.
    static func statusText(_ info: BatteryInfo?) -> String {
        switch info?.state {
        case .charging?:    "Charging"
        case .discharging?: "On battery"
        case .charged?:     "Charged"
        case .ac?:          "On power adapter, not charging"
        case nil:           "—"
        }
    }
}
