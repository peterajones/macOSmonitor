import Testing
@testable import macOSmonitor

struct VitalsHistoryTests {
    private func vitals(cpu: Double, memory: UInt64,
                        netIn: Double, netOut: Double,
                        diskRead: Double, diskWrite: Double,
                        perCore: [Double] = []) -> SystemVitals {
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
                     perCoreUsagePercent: perCore,
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

    @Test func longMemorySeriesOutlastsTheShortWindow() {
        var history = VitalsHistory(capacity: 2)
        for i in 1...4 {
            history.append(vitals(cpu: 0, memory: UInt64(i),
                                  netIn: 0, netOut: 0, diskRead: 0, diskWrite: 0))
        }
        #expect(history.memoryUsed.values == [3, 4])
        #expect(history.memoryUsedLong.values == [1, 2, 3, 4])
        #expect(history.memoryUsedLong.capacity == 300)
    }

    private func appendCores(_ history: inout VitalsHistory, _ perCore: [Double]) {
        history.append(vitals(cpu: 0, memory: 0, netIn: 0, netOut: 0,
                              diskRead: 0, diskWrite: 0, perCore: perCore))
    }

    @Test func perCoreSeriesTrackEachCoreSeparately() {
        // Three cores, two samples: a transposed implementation (one series per sample)
        // gives two series of three instead of three series of two.
        var history = VitalsHistory(capacity: 60)
        appendCores(&history, [10, 20, 30])
        appendCores(&history, [11, 21, 31])
        #expect(history.perCore.map(\.values) == [[10, 11], [20, 21], [30, 31]])
    }

    @Test func perCoreSeriesUseTheHistoryCapacity() {
        var history = VitalsHistory(capacity: 2)
        for i in 1...3 { appendCores(&history, [Double(i), Double(i * 10)]) }
        #expect(history.perCore.map(\.values) == [[2, 3], [20, 30]])
    }

    @Test func aChangedCoreCountStartsFresh() {
        var history = VitalsHistory(capacity: 60)
        appendCores(&history, [1, 2])
        appendCores(&history, [3, 4, 5])
        #expect(history.perCore.map(\.values) == [[3], [4], [5]])
    }

    @Test func aSampleWithoutPerCoreDataIsSkipped() {
        var history = VitalsHistory(capacity: 60)
        appendCores(&history, [10, 20])
        appendCores(&history, [])
        #expect(history.perCore.map(\.values) == [[10], [20]])
        #expect(history.cpu.values.count == 2)   // the overall series still advanced
    }
}
