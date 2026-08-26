import Testing
@testable import macOSmonitor

struct VitalsHistoryTests {
    private func vitals(cpu: Double, memory: UInt64,
                        netIn: Double, netOut: Double,
                        diskRead: Double, diskWrite: Double) -> SystemVitals {
        SystemVitals(cpuUsagePercent: cpu,
                     usedMemoryBytes: memory,
                     totalMemoryBytes: 16_000_000_000,
                     coreCount: 8,
                     activeCoreCount: 8,
                     thermalState: "Nominal",
                     lowPowerMode: false,
                     uptime: 100,
                     osVersion: "macOS 26.5",
                     networkInBytesPerSec: netIn,
                     networkOutBytesPerSec: netOut,
                     battery: nil,
                     perCoreUsagePercent: [],
                     diskReadBytesPerSec: diskRead,
                     diskWriteBytesPerSec: diskWrite)
    }

    @Test func oneAppendPopulatesAllSixSeries() {
        var history = VitalsHistory(capacity: 60)
        history.append(vitals(cpu: 42, memory: 8_000_000_000,
                              netIn: 1_000, netOut: 2_000,
                              diskRead: 3_000, diskWrite: 4_000))

        #expect(history.cpu.values == [42])
        #expect(history.memoryUsed.values == [8_000_000_000])
        #expect(history.networkIn.values == [1_000])
        #expect(history.networkOut.values == [2_000])
        #expect(history.diskRead.values == [3_000])
        #expect(history.diskWrite.values == [4_000])
    }

    @Test func seriesStayIndexAligned() {
        var history = VitalsHistory(capacity: 60)
        for i in 1...5 {
            history.append(vitals(cpu: Double(i), memory: UInt64(i),
                                  netIn: Double(i), netOut: Double(i),
                                  diskRead: Double(i), diskWrite: Double(i)))
        }
        #expect(history.cpu.values.count == 5)
        #expect(history.memoryUsed.values.count == history.cpu.values.count)
        #expect(history.diskWrite.values.count == history.cpu.values.count)
    }

    @Test func capacityPropagatesToEverySeries() {
        var history = VitalsHistory(capacity: 2)
        for i in 1...4 {
            history.append(vitals(cpu: Double(i), memory: 0,
                                  netIn: 0, netOut: 0, diskRead: 0, diskWrite: 0))
        }
        #expect(history.cpu.values == [3, 4])
        #expect(history.networkIn.capacity == 2)
    }
}
