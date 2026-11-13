import Testing
import Foundation
@testable import macOSmonitor

struct ProcessPowerTests {
    final class Clock: @unchecked Sendable { var nanos: UInt64 = 0 }

    private func energy(_ nanojoules: UInt64) -> ProcTaskSample {
        ProcTaskSample(residentBytes: 1, cpuTimeNanos: 0, energyNanojoules: nanojoules)
    }

    @Test func wattsComeFromTheEnergyCounterOnTheSecondTick() async {
        let procs = FakeProcInfo()
        procs.pids = [10, 11]
        procs.results = [10: energy(1_000_000_000), 11: energy(5_000_000_000)]
        let clock = Clock()
        let sampler = ProcessSampler(source: procs, apps: FakeRegularApps(), now: { clock.nanos })
        let first = await sampler.sample()
        #expect(first.allSatisfy { $0.powerWatts == nil })              // no baseline yet

        // 10: +6 J in 2 s = 3 W. 11: +1 J = 0.5 W (a sampler mixing up PIDs gets these swapped).
        procs.results = [10: energy(7_000_000_000), 11: energy(6_000_000_000)]
        clock.nanos = 2_000_000_000
        let second = await sampler.sample()
        #expect(second.first { $0.pid == 10 }?.powerWatts == 3)
        #expect(second.first { $0.pid == 11 }?.powerWatts == 0.5)
    }

    @Test func aCounterThatGoesBackwardsIsNotAReading() async {
        // A PID reused by a new process starts its counter again.
        let procs = FakeProcInfo()
        procs.pids = [10]
        procs.results = [10: energy(9_000_000_000)]
        let clock = Clock()
        let sampler = ProcessSampler(source: procs, apps: FakeRegularApps(), now: { clock.nanos })
        _ = await sampler.sample()
        procs.results = [10: energy(1_000)]
        clock.nanos = 1_000_000_000
        #expect(await sampler.sample().first?.powerWatts == nil)
    }

    @Test func deniedProcessesGetPowerFromTheHelper() async {
        let procs = FakeProcInfo()
        procs.pids = [1]                                               // launchd: denied to us
        let helper = FakePrivilegedAccess()
        helper.samples = [1: energy(0)]
        let clock = Clock()
        let sampler = ProcessSampler(source: procs, apps: FakeRegularApps(), privileged: helper,
                                     now: { clock.nanos })
        _ = await sampler.sample()
        helper.samples = [1: energy(250_000_000)]
        clock.nanos = 1_000_000_000
        #expect(await sampler.sample().first?.powerWatts == 0.25)
    }

    /// A protocol-3 helper sends no energy: its processes still get memory and CPU, just no
    /// power, and our own processes keep theirs (read locally, never from the helper).
    @Test func aHelperWithoutEnergyStillFillsMemoryAndCPU() async {
        let procs = FakeProcInfo()
        procs.pids = [1, 42]
        procs.results = [42: energy(0)]                                // 1 is denied to us
        let helper = FakePrivilegedAccess()
        helper.samples = [1: ProcTaskSample(residentBytes: 9_000, cpuTimeNanos: 0),
                          42: energy(999_000_000_000)]                 // must not override ours
        let clock = Clock()
        let sampler = ProcessSampler(source: procs, apps: FakeRegularApps(), privileged: helper,
                                     now: { clock.nanos })
        _ = await sampler.sample()
        procs.results = [42: energy(500_000_000)]
        helper.samples[1] = ProcTaskSample(residentBytes: 9_000, cpuTimeNanos: 1_000_000_000)
        clock.nanos = 1_000_000_000
        let rows = await sampler.sample()
        let root = rows.first { $0.pid == 1 }
        #expect(root?.memoryBytes == 9_000)
        #expect(root?.cpuPercent == 100)
        #expect(root?.powerWatts == nil)
        #expect(rows.first { $0.pid == 42 }?.powerWatts == 0.5)
    }

    @Test func samplesCarryEnergyOverTheWireAndOldPayloadsStillDecode() throws {
        let decoded = try #require(HelperWire.decodeSamples(HelperWire.encodeSamples([7: energy(123)])))
        #expect(decoded[7]?.energyNanojoules == 123)
        // A protocol-3 helper sends [resident, cpu] only.
        let old = try #require(HelperWire.decodeSamples(Data(#"{"7":[100,200]}"#.utf8)))
        #expect(old[7]?.residentBytes == 100)
        #expect(old[7]?.cpuTimeNanos == 200)
        #expect(old[7]?.energyNanojoules == nil)
    }

    @Test func topByPowerSkipsUnknownsAndBreaksTiesByPID() {
        func row(_ pid: pid_t, _ watts: Double?) -> ProcessInfoRow {
            var row = ProcessInfoRow(pid: pid, name: "p\(pid)", cpuPercent: nil, memoryBytes: nil)
            row.powerWatts = watts
            return row
        }
        let rows = [row(1, 0.5), row(2, nil), row(3, 4), row(4, 0.5), row(5, 2)]
        #expect(ProcessInfoRow.topByPower(rows, limit: 3).map(\.pid) == [3, 5, 1])
        #expect(ProcessInfoRow.topByPower(rows, limit: 9).map(\.pid) == [3, 5, 1, 4])
        #expect(row(3, 4).powerText == "4.00")
        #expect(row(2, nil).powerText == "—")
    }
}
