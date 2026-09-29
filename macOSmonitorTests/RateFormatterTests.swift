import Testing
@testable import macOSmonitor

struct RateFormatterTests {
    @Test func unitBoundariesSwitchAtExactlyOneThousand() {
        #expect(SystemVitals.rate(999) == "999 B/s")
        #expect(SystemVitals.rate(1_000) == "1 KB/s")
        #expect(SystemVitals.rate(999_499) == "999 KB/s")
        #expect(SystemVitals.rate(1_000_000) == "1.0 MB/s")
        #expect(SystemVitals.rate(999_949_999) == "999.9 MB/s")
        #expect(SystemVitals.rate(1_000_000_000) == "1.0 GB/s")
    }

    @Test func keepsDecimalPlacesOnlyForMegabytesAndAbove() {
        #expect(SystemVitals.rate(340_000) == "340 KB/s")
        #expect(SystemVitals.rate(1_240_000) == "1.2 MB/s")
        #expect(SystemVitals.rate(2_340_000_000) == "2.3 GB/s")
    }

    @Test func negativeRatesClampToZero() {
        #expect(SystemVitals.rate(-5) == "0 B/s")
    }

    @Test func compositeStringsUseTheSharedFormatter() {
        var v = SystemVitals(cpuUsagePercent: 0, usedMemoryBytes: 0, totalMemoryBytes: 0,
                             coreCount: 8, activeCoreCount: 8, thermalState: "Nominal",
                             lowPowerMode: false, uptime: 0, osVersion: "macOS 26.5")
        v.networkInBytesPerSec = 1_200_000
        v.networkOutBytesPerSec = 340_000
        v.diskReadBytesPerSec = 750_000
        v.diskWriteBytesPerSec = 0
        #expect(v.networkText == "↓ 1.2 MB/s  ↑ 340 KB/s")
        #expect(v.diskText == "R 750 KB/s  W 0 B/s")
    }
}
