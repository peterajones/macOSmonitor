import Testing
import Foundation
@testable import macOSmonitor

struct HostStatsTests {
    let sut = HostStats()

    @Test func cpuTicksReportEveryCore() {
        let cores = sut.cpuTicks()
        #expect(cores?.isEmpty == false)
        #expect(cores?.count == ProcessInfo.processInfo.processorCount)
        #expect((cores?.allSatisfy { $0.total > 0 }) == true)
    }

    @Test func cachedMemoryIsWithinPhysical() {
        let mem = sut.memory()
        #expect((mem?.cached ?? 0) > 0)
        #expect((mem?.cached ?? .max) < (mem?.total ?? 0))
    }

    @Test func memoryCategoriesAreReported() {
        let mem = sut.memory()
        #expect((mem?.wired ?? 0) > 0)
        #expect((mem?.app ?? 0) > 0)
        #expect((mem?.pageIns ?? 0) > 0)
        #expect((mem?.wired ?? .max) < (mem?.total ?? 0))
        #expect((mem?.app ?? .max) < (mem?.total ?? 0))
    }

    @Test func swapUsageIsReadable() {
        let swap = sut.swapUsage()
        #expect(swap != nil)
        #expect((swap?.used ?? .max) <= (swap?.total ?? 0))
    }

    @Test func memoryPressureLevelIsAKnownKernelValue() {
        #expect([Int32(1), 2, 4].contains(sut.memoryPressureLevel() ?? 0))
    }

    @Test func memoryIsSaneAgainstPhysical() {
        let mem = sut.memory()
        #expect(mem?.total == ProcessInfo.processInfo.physicalMemory)
        #expect((mem?.used ?? 0) > 0)
        #expect((mem?.used ?? .max) < (mem?.total ?? 0))
    }
}
