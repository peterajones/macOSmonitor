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

    @Test func memoryIsSaneAgainstPhysical() {
        let mem = sut.memory()
        #expect(mem?.total == ProcessInfo.processInfo.physicalMemory)
        #expect((mem?.used ?? 0) > 0)
        #expect((mem?.used ?? .max) < (mem?.total ?? 0))
    }
}
