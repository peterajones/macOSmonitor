import Foundation
import Testing
@testable import macOSmonitor

final class FakeHostStats: HostStatsProviding, @unchecked Sendable {
    var ticks: (busy: UInt64, total: UInt64)?
    var mem: (used: UInt64, total: UInt64)?
    func cpuTicks() -> (busy: UInt64, total: UInt64)? { ticks }
    func memory() -> (used: UInt64, total: UInt64)? { mem }
}

final class FakeNetworkStats: NetworkStatsProviding, @unchecked Sendable {
    var next: (received: UInt64, sent: UInt64)?
    func counters() -> (received: UInt64, sent: UInt64)? { next }
}

final class FakeBatteryStats: BatteryStatsProviding, @unchecked Sendable {
    var info: BatteryInfo?
    func read() -> BatteryInfo? { info }
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

    @Test func networkRateFromDeltasOverClock() async {
        let net = FakeNetworkStats()
        var clock: UInt64 = 0
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: net, now: { clock })

        net.next = (received: 1_000, sent: 500)
        let first = await sampler.sample()
        #expect(first.networkInBytesPerSec == 0)          // no baseline

        clock = 1_000_000_000                             // +1.0 s
        net.next = (received: 1_001_000, sent: 340_500)   // +1_000_000 in / +340_000 out
        let second = await sampler.sample()
        #expect(second.networkInBytesPerSec == 1_000_000)
        #expect(second.networkOutBytesPerSec == 340_000)
    }

    @Test func networkRateZeroOnCounterDrop() async {
        let net = FakeNetworkStats()
        var clock: UInt64 = 0
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: net, now: { clock })

        net.next = (received: 5_000, sent: 5_000)
        _ = await sampler.sample()
        clock = 1_000_000_000
        net.next = (received: 1_000, sent: 1_000)          // counters dropped (wrap / iface reset)
        let s = await sampler.sample()
        #expect(s.networkInBytesPerSec == 0)
        #expect(s.networkOutBytesPerSec == 0)
    }

    @Test func vitalsPublishBatteryWhenPresent() async {
        let fake = FakeBatteryStats()
        fake.info = BatteryInfo(chargePercent: 84, state: .discharging, timeRemainingMinutes: 197)
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: FakeNetworkStats(),
                                          battery: fake)
        let v = await sampler.sample()
        #expect(v.battery == fake.info)
    }

    @Test func vitalsHaveNilBatteryWhenAbsent() async {
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: FakeNetworkStats(),
                                          battery: FakeBatteryStats())   // info stays nil
        let v = await sampler.sample()
        #expect(v.battery == nil)
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
