import Foundation
import Testing
@testable import macOSmonitor

struct SystemVitalsTests {
    private func make(cpu: Double = 0, used: UInt64 = 0, total: UInt64 = 0,
                      cores: Int = 8, uptime: TimeInterval = 0,
                      netIn: Double = 0, netOut: Double = 0) -> SystemVitals {
        SystemVitals(cpuUsagePercent: cpu, usedMemoryBytes: used, totalMemoryBytes: total,
                     coreCount: cores, activeCoreCount: cores, thermalState: "Nominal",
                     lowPowerMode: false, uptime: uptime, osVersion: "macOS 26.5",
                     networkInBytesPerSec: netIn, networkOutBytesPerSec: netOut)
    }

    @Test func cpuTextRoundsToWholePercent() {
        #expect(make(cpu: 34.4).cpuText == "34%")
    }

    @Test func memoryBreakdownTextIsBinaryGB() {
        var v = make(used: 16_106_127_360, total: 19_327_352_832)
        v.memoryReading = MemoryReading(used: 16_106_127_360, total: 19_327_352_832,
                                        cached: 4_617_089_843, wired: 3_758_096_384,
                                        compressed: 6_549_825_126, app: 5_690_831_667)
        v.swap = SwapUsage(used: 24_588_687_770, total: 25_769_803_776)
        v.memoryPressure = .warning

        #expect(v.usedMemoryText == "15.0 GB")
        #expect(v.availableMemoryText == "3.0 GB")
        #expect(v.cachedMemoryText == "4.3 GB")
        #expect(v.wiredMemoryText == "3.5 GB")
        #expect(v.compressedMemoryText == "6.1 GB")
        #expect(v.appMemoryText == "5.3 GB")
        #expect(v.swapText == "22.9 / 24.0 GB")
        #expect(v.memoryPressureText == "Warning")
    }

    @Test func memoryPercentIsUsedOverTotal() {
        let v = make(used: 16_106_127_360, total: 19_327_352_832)
        #expect(abs(v.memoryUsedFraction - 16_106_127_360.0 / 19_327_352_832.0) < 1e-12)
        #expect(v.memoryPercentText == "83.3%")
    }

    @Test func zeroTotalMemoryHasNoPercent() {
        let v = make(used: 5, total: 0)
        #expect(v.memoryUsedFraction == 0)
        #expect(v.memoryPercentText == "—")
    }

    @Test func pageCountsShowEveryDigit() {
        var v = make()
        v.memoryReading = MemoryReading(used: 0, total: 0, pageIns: 593_588_718, pageOuts: 810_138)

        #expect(v.pageInsText.filter(\.isNumber) == "593588718")
        #expect(v.pageOutsText.filter(\.isNumber) == "810138")
    }

    @Test func unknownMemoryBreakdownShowsADash() {
        let v = make(cpu: 0, used: 0, total: 0)

        #expect(v.usedMemoryText == "—")
        #expect(v.wiredMemoryText == "—")
        #expect(v.compressedMemoryText == "—")
        #expect(v.appMemoryText == "—")
        #expect(v.pageInsText == "—")
        #expect(v.pageOutsText == "—")
        #expect(v.cachedMemoryText == "—")
        #expect(v.availableMemoryText == "—")
        #expect(v.swapText == "—")
        #expect(v.memoryPressureText == "—")
    }

    @Test func memoryTextIsBinaryGB() {
        #expect(make(used: 13_207_024_435, total: 34_359_738_368).memoryText == "12.3 / 32 GB")
    }

    @Test func uptimeTextDaysHours() {
        #expect(make(uptime: 3 * 86_400 + 4 * 3_600 + 30 * 60).uptimeText == "3d 4h")
    }

    @Test func networkTextFormatsAdaptiveUnits() {
        #expect(make(netIn: 1_200_000, netOut: 340_000).networkText == "↓ 1.2 MB/s  ↑ 340 KB/s")
    }

    @Test func networkTextZero() {
        #expect(make(netIn: 0, netOut: 0).networkText == "↓ 0 B/s  ↑ 0 B/s")
    }
}
