import Testing
@testable import macOSmonitor

/// What each of the Summary's bottom-row tiles says, and how full its meter is.
struct SummaryTileTests {
    private func vitals(netIn: Double = 0, netOut: Double = 0, read: Double = 0, write: Double = 0,
                        thermal: String = "Nominal", battery: BatteryInfo? = nil) -> SystemVitals {
        SystemVitals(cpuUsagePercent: 0, usedMemoryBytes: 0, totalMemoryBytes: 1, coreCount: 1,
                     activeCoreCount: 1, thermalState: thermal, lowPowerMode: false,
                     uptime: 0, osVersion: "macOS 27.2",
                     networkInBytesPerSec: netIn, networkOutBytesPerSec: netOut,
                     battery: battery, diskReadBytesPerSec: read, diskWriteBytesPerSec: write)
    }

    private func history(_ values: [Double]) -> MetricHistory {
        var history = MetricHistory(capacity: 60)
        values.forEach { history.append($0) }
        return history
    }

    // MARK: Network and Disk: a meter against the busiest second in the window, labelled as such

    @Test func networkShowsTheTotalAndItsSplit() {
        let tile = SummaryTile.network(vitals(netIn: 6_000, netOut: 1_000),
                                       inHistory: history([6_000]), outHistory: history([1_000]))
        #expect(tile.value == "7 KB/s")
        #expect(tile.detail == "↓ 6 KB/s · ↑ 1 KB/s")
    }

    @Test func networkMeterIsTheShareOfTheWindowsBusiestSecond() {
        // The busiest second is 30 + 10 = 40, not the largest single value (35, in), nor the
        // two peaks added (35 + 10 = 45): in and out are summed second by second.
        let tile = SummaryTile.network(vitals(netIn: 8, netOut: 2),
                                       inHistory: history([30, 35, 8]), outHistory: history([10, 0, 2]))
        #expect(tile.fraction == 0.25)
        #expect(tile.scale == "Peak 40 B/s")
    }

    @Test func diskMeterIsTheShareOfTheWindowsBusiestSecond() {
        let tile = SummaryTile.disk(vitals(read: 50, write: 50),
                                    readHistory: history([300, 100, 50]), writeHistory: history([100, 50, 50]))
        #expect(tile.value == "100 B/s")
        #expect(tile.detail == "R 50 B/s · W 50 B/s")
        #expect(tile.fraction == 0.25)
        #expect(tile.scale == "Peak 400 B/s")
    }

    @Test func anIdleWindowHasAnEmptyMeter() {
        let tile = SummaryTile.disk(vitals(), readHistory: history([0, 0]), writeHistory: history([0, 0]))
        #expect(tile.fraction == 0)
        #expect(tile.scale == nil)
    }

    @Test func noReadingYetSaysSo() {
        let tile = SummaryTile.network(nil, inHistory: history([]), outHistory: history([]))
        #expect(tile.value == "—")
        #expect(tile.fraction == 0)
    }

    // MARK: Battery

    @Test func batteryOnItsOwnPowerShowsTimeRemaining() {
        let tile = SummaryTile.battery(BatteryInfo(chargePercent: 52, state: .discharging, timeRemainingMinutes: 90))
        #expect(tile.value == "52%")
        #expect(tile.detail == "1:30 remaining")
        #expect(tile.fraction == 0.52)
    }

    @Test(arguments: [
        (BatteryInfo.State.charging, Optional(80), "Charging · full in 1:20"),
        (.charging, nil, "Charging"),
        (.discharging, nil, "Calculating…"),
        (.charged, nil, "Charged"),
        (.ac, nil, "On power, not charging"),
    ])
    func batteryDetail(state: BatteryInfo.State, minutes: Int?, expected: String) {
        let tile = SummaryTile.battery(BatteryInfo(chargePercent: 90, state: state, timeRemainingMinutes: minutes))
        #expect(tile.detail == expected)
    }

    // MARK: Thermal: the four pressure levels fill the meter in quarters

    @Test(arguments: [("Nominal", 0.25), ("Fair", 0.5), ("Serious", 0.75), ("Critical", 1.0)])
    func thermalLevelFillsAQuarterPerStep(state: String, fraction: Double) {
        #expect(SummaryTile.thermal(vitals(thermal: state), cpuCelsius: nil).fraction == fraction)
    }

    @Test func thermalShowsTheStateAndTheHottestCPUDie() {
        let tile = SummaryTile.thermal(vitals(thermal: "Fair"), cpuCelsius: 49.4)
        #expect(tile.value == "Fair")
        #expect(tile.detail == "CPU 49 °C")
    }

    @Test func thermalWithoutSensorsSaysPressureOnly() {
        let tile = SummaryTile.thermal(vitals(thermal: "Nominal"), cpuCelsius: nil)
        #expect(tile.detail == "Thermal pressure")
    }

    @Test func anUnknownThermalStateHasNoMeterReading() {
        #expect(SummaryTile.thermal(vitals(thermal: "Unknown"), cpuCelsius: nil).fraction == 0)
        #expect(SummaryTile.thermal(nil, cpuCelsius: nil).value == "—")
    }
}
