import Foundation
import Testing
@testable import macOSmonitor

struct SystemVitalsTests {
    private func make(cpu: Double = 0, used: UInt64 = 0, total: UInt64 = 0,
                      cores: Int = 8, uptime: TimeInterval = 0) -> SystemVitals {
        SystemVitals(cpuUsagePercent: cpu, usedMemoryBytes: used, totalMemoryBytes: total,
                     coreCount: cores, activeCoreCount: cores, thermalState: "Nominal",
                     lowPowerMode: false, uptime: uptime, osVersion: "macOS 26.5")
    }

    @Test func cpuTextRoundsToWholePercent() {
        #expect(make(cpu: 34.4).cpuText == "CPU 34%")
    }

    @Test func memoryTextIsDecimalGB() {
        #expect(make(used: 12_300_000_000, total: 32_000_000_000).memoryText == "12.3 / 32 GB")
    }

    @Test func coresText() {
        #expect(make(cores: 10).coresText == "10 cores")
    }

    @Test func uptimeTextDaysHours() {
        #expect(make(uptime: 3 * 86_400 + 4 * 3_600 + 30 * 60).uptimeText == "up 3d 4h")
    }
}
