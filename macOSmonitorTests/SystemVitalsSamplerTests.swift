import Foundation
import Testing
@testable import macOSmonitor

final class FakeHostStats: HostStatsProviding, @unchecked Sendable {
    var ticks: (busy: UInt64, total: UInt64)?
    var mem: (used: UInt64, total: UInt64)?
    func cpuTicks() -> (busy: UInt64, total: UInt64)? { ticks }
    func memory() -> (used: UInt64, total: UInt64)? { mem }
}

struct SystemVitalsSamplerTests {
    @Test func firstTickZeroThenDeltaPercent() async {
        let fake = FakeHostStats()
        fake.mem = (used: 1_000, total: 2_000)
        fake.ticks = (busy: 100, total: 1_000)
        let sampler = SystemVitalsSampler(host: fake)

        let first = await sampler.sample()
        #expect(first.cpuUsagePercent == 0)             // no baseline yet
        #expect(first.usedMemoryBytes == 1_000)
        #expect(first.totalMemoryBytes == 2_000)

        fake.ticks = (busy: 150, total: 1_100)          // +50 busy / +100 total → 50%
        let second = await sampler.sample()
        #expect(second.cpuUsagePercent == 50)
    }

    @Test func vitalsReflectRealProcessInfoFacts() async {
        let sampler = SystemVitalsSampler(host: FakeHostStats())
        let v = await sampler.sample()
        #expect(v.coreCount == ProcessInfo.processInfo.processorCount)
        #expect(v.osVersion.hasPrefix("macOS "))
    }

    @Test func counterWraparoundDoesNotCrashAndYieldsZero() async {
        // busy goes backwards while total advances (per-core 32-bit wrap): must not trap.
        let fake = FakeHostStats()
        fake.ticks = (busy: 500, total: 1_000)
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()                          // baseline

        fake.ticks = (busy: 100, total: 1_100)              // busy dropped, total rose
        let next = await sampler.sample()
        #expect(next.cpuUsagePercent == 0)                  // skipped safely, no crash
    }
}
