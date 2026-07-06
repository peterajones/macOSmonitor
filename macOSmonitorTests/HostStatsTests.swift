import Testing
import Foundation
@testable import macOSmonitor

struct HostStatsTests {
    let sut = HostStats()

    @Test func cpuTicksAccumulate() {
        #expect((sut.cpuTicks()?.total ?? 0) > 0)
    }

    @Test func memoryIsSaneAgainstPhysical() {
        let mem = sut.memory()
        #expect(mem?.total == ProcessInfo.processInfo.physicalMemory)
        #expect((mem?.used ?? 0) > 0)
        #expect((mem?.used ?? .max) < (mem?.total ?? 0))
    }
}
