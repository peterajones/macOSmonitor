import Testing
@testable import macOSmonitor

struct BatteryInfoTests {
    @Test func dischargingWithTime() {
        let b = BatteryInfo(chargePercent: 84, state: .discharging, timeRemainingMinutes: 197)
        #expect(b.displayText == "84% · 3:17")
    }

    @Test func chargingWithTime() {
        let b = BatteryInfo(chargePercent: 84, state: .charging, timeRemainingMinutes: 80)
        #expect(b.displayText == "84% ⚡ 1:20")
    }

    @Test func chargedShowsBolt() {
        let b = BatteryInfo(chargePercent: 100, state: .charged, timeRemainingMinutes: nil)
        #expect(b.displayText == "100% ⚡")
    }

    @Test func acHoldingShowsBolt() {
        let b = BatteryInfo(chargePercent: 80, state: .ac, timeRemainingMinutes: nil)
        #expect(b.displayText == "80% ⚡")
    }

    @Test func dischargingCalculatingHidesTime() {
        let b = BatteryInfo(chargePercent: 84, state: .discharging, timeRemainingMinutes: nil)
        #expect(b.displayText == "84%")
    }
}
