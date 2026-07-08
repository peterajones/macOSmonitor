import Testing
@testable import macOSmonitor

struct BatteryStatsTests {
    // This dev machine is a laptop with a battery.
    @Test func readsBatteryOnThisLaptop() {
        let info = BatteryStats().read()
        #expect(info != nil)
        let pct = info?.chargePercent ?? -1
        #expect(pct >= 0 && pct <= 100)
    }
}
