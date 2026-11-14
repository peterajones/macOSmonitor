import Testing
@testable import macOSmonitor

/// Graphs glide at 30 fps, halved on battery or in Low Power Mode: on a 12-core CPU panel
/// that is ~18% of a core at 30 fps against ~12% at 15 (benchmarked 2026-11-14).
struct GraphFrameRateTests {
    private func vitals(battery: BatteryInfo.State?, lowPower: Bool = false) -> SystemVitals {
        SystemVitals(cpuUsagePercent: 0, usedMemoryBytes: 0, totalMemoryBytes: 1, coreCount: 1,
                     activeCoreCount: 1, thermalState: "Nominal", lowPowerMode: lowPower,
                     uptime: 0, osVersion: "macOS 27.2",
                     battery: battery.map { BatteryInfo(chargePercent: 50, state: $0, timeRemainingMinutes: nil) })
    }

    @Test func fullRateBeforeTheFirstSample() {
        #expect(GraphFrameRate.rate(for: nil) == 30)
    }

    @Test func fullRateOnADesktopWithNoBattery() {
        #expect(GraphFrameRate.rate(for: vitals(battery: nil)) == 30)
    }

    @Test(arguments: [BatteryInfo.State.charging, .charged, .ac])
    func fullRateOnPower(_ state: BatteryInfo.State) {
        #expect(GraphFrameRate.rate(for: vitals(battery: state)) == 30)
    }

    @Test func halfRateOnBattery() {
        #expect(GraphFrameRate.rate(for: vitals(battery: .discharging)) == 15)
    }

    @Test func halfRateInLowPowerModeEvenOnPower() {
        #expect(GraphFrameRate.rate(for: vitals(battery: .ac, lowPower: true)) == 15)
        #expect(GraphFrameRate.rate(for: vitals(battery: nil, lowPower: true)) == 15)
    }
}
