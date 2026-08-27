import Foundation
import Testing
@testable import macOSmonitor

final class FakeHostStats: HostStatsProviding, @unchecked Sendable {
    var ticks: [CoreTicks]?
    var mem: (used: UInt64, total: UInt64)?
    func cpuTicks() -> [CoreTicks]? { ticks }
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

final class FakeDiskStats: DiskStatsProviding, @unchecked Sendable {
    var next: (read: UInt64, written: UInt64)?
    func counters() -> (read: UInt64, written: UInt64)? { next }
}

struct SystemVitalsSamplerTests {
    @Test func firstTickZeroThenDeltaPercent() async {
        let fake = FakeHostStats()
        fake.mem = (used: 1_000, total: 2_000)
        fake.ticks = [CoreTicks(busy: 100, total: 1_000)]
        let sampler = SystemVitalsSampler(host: fake)

        let first = await sampler.sample()
        #expect(first.cpuUsagePercent == 0)             // no baseline yet
        #expect(first.usedMemoryBytes == 1_000)
        #expect(first.totalMemoryBytes == 2_000)

        fake.ticks = [CoreTicks(busy: 150, total: 1_100)]   // +50 busy / +100 total → 50%
        let second = await sampler.sample()
        #expect(second.cpuUsagePercent == 50)
    }

    @Test func perCorePercentagesAreReportedIndividually() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 0, total: 100), CoreTicks(busy: 0, total: 100)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()                        // establish baseline

        fake.ticks = [CoreTicks(busy: 25, total: 200),    // +25/+100 → 25%
                      CoreTicks(busy: 75, total: 200)]    // +75/+100 → 75%
        let sample = await sampler.sample()
        #expect(sample.perCoreUsagePercent == [25, 75])
    }

    @Test func aggregateIsTheSumOfCoreDeltasNotTheAverageOfPercents() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 0, total: 0), CoreTicks(busy: 0, total: 0)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()

        // core 0 busy 30 of 100; core 1 busy 70 of 300 → total 100 busy of 400 = 25%
        fake.ticks = [CoreTicks(busy: 30, total: 100), CoreTicks(busy: 70, total: 300)]
        let sample = await sampler.sample()
        #expect(sample.cpuUsagePercent == 25)
    }

    @Test func oneCoreWrappingDoesNotCorruptTheOthers() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 100, total: 1_000), CoreTicks(busy: 0, total: 100)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()

        // core 0 wrapped (counters went backwards); core 1 advanced +50/+100 → 50%
        fake.ticks = [CoreTicks(busy: 5, total: 20), CoreTicks(busy: 50, total: 200)]
        let sample = await sampler.sample()
        #expect(sample.perCoreUsagePercent == [0, 50])
        #expect(sample.cpuUsagePercent == 50)     // wrapped core excluded from the aggregate
    }

    @Test func coreCountChangeResetsToBaseline() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 0, total: 100)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()

        fake.ticks = [CoreTicks(busy: 50, total: 200), CoreTicks(busy: 50, total: 200)]
        let sample = await sampler.sample()
        #expect(sample.perCoreUsagePercent == [0, 0])
        #expect(sample.cpuUsagePercent == 0)
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

    @Test func diskRatesAreBytesPerSecondOverElapsedTime() async {
        let disk = FakeDiskStats()
        disk.next = (read: 1_000, written: 2_000)
        var clock: UInt64 = 0
        let sampler = SystemVitalsSampler(host: FakeHostStats(),
                                          disk: disk,
                                          now: { clock })

        let first = await sampler.sample()
        #expect(first.diskReadBytesPerSec == 0)        // no baseline yet

        clock = 2_000_000_000                          // +2 seconds
        disk.next = (read: 3_000, written: 2_500)      // +2000 read, +500 written
        let second = await sampler.sample()
        #expect(second.diskReadBytesPerSec == 1_000)   // 2000 bytes / 2s
        #expect(second.diskWriteBytesPerSec == 250)
    }

    @Test func diskCounterGoingBackwardsYieldsZeroNotATrap() async {
        let disk = FakeDiskStats()
        disk.next = (read: 5_000, written: 5_000)
        var clock: UInt64 = 0
        let sampler = SystemVitalsSampler(host: FakeHostStats(), disk: disk, now: { clock })
        _ = await sampler.sample()

        clock = 1_000_000_000
        disk.next = (read: 10, written: 10)            // counters reset
        let sample = await sampler.sample()
        #expect(sample.diskReadBytesPerSec == 0)
        #expect(sample.diskWriteBytesPerSec == 0)
    }

    @Test func counterWraparoundDoesNotCrashAndYieldsZero() async {
        // busy goes backwards while total advances (per-core 32-bit wrap): must not trap.
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 500, total: 1_000)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()                          // baseline

        fake.ticks = [CoreTicks(busy: 100, total: 1_100)]   // busy dropped, total rose
        let next = await sampler.sample()
        #expect(next.cpuUsagePercent == 0)                  // skipped safely, no crash
    }
}
