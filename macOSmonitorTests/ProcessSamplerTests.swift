import Testing
import Darwin
@testable import macOSmonitor

/// Scriptable stand-in for ProcInfo. Mutate `results` between `sample()` calls
/// to simulate successive ticks.
final class FakeProcInfo: ProcInfoProviding, @unchecked Sendable {
    var pids: [pid_t] = []
    var names: [pid_t: String] = [:]
    var results: [pid_t: ProcTaskSample] = [:]
    func listPIDs() -> [pid_t] { pids }
    func sample(pid: pid_t) -> ProcTaskSample? { results[pid] }
    func name(pid: pid_t) -> String { names[pid] ?? "(pid \(pid))" }
}

struct ProcessSamplerTests {
    @Test func firstTickHasNoCPUBaseline() async {
        let fake = FakeProcInfo()
        fake.pids = [42]; fake.names = [42: "worker"]
        fake.results = [42: ProcTaskSample(residentBytes: 1000, cpuTimeNanos: 0)]
        let sampler = ProcessSampler(source: fake, now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.count == 1)
        #expect(rows.first?.cpuPercent == nil)
        #expect(rows.first?.memoryBytes == 1000)
    }

    @Test func cpuPercentIsDeltaOverWallTime() async {
        let fake = FakeProcInfo()
        fake.pids = [42]; fake.names = [42: "worker"]
        let clock = FakeClock()
        let sampler = ProcessSampler(source: fake, now: { clock.now })

        fake.results = [42: ProcTaskSample(residentBytes: 1000, cpuTimeNanos: 0)]
        _ = await sampler.sample()                       // establish baseline at t=0

        clock.now = 1_000_000_000                            // +1.0s wall
        fake.results = [42: ProcTaskSample(residentBytes: 1000, cpuTimeNanos: 500_000_000)] // +0.5s CPU
        let rows = await sampler.sample()

        #expect(rows.first?.cpuPercent == 50.0)
    }

    @Test func ownedRowCarriesCumulativeCPUTime() async {
        let fake = FakeProcInfo()
        fake.pids = [42]; fake.names = [42: "worker"]
        fake.results = [42: ProcTaskSample(residentBytes: 2048, cpuTimeNanos: 7_000_000_000)]
        let sampler = ProcessSampler(source: fake, now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.first?.cpuTimeNanos == 7_000_000_000)
    }

    @Test func deniedProcessYieldsNamePidOnly() async {
        let fake = FakeProcInfo()
        fake.pids = [7]; fake.names = [7: "root-proc"]
        fake.results = [:]                               // sample() returns nil → EPERM path
        let sampler = ProcessSampler(source: fake, now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.first?.name == "root-proc")
        #expect(rows.first?.cpuPercent == nil)
        #expect(rows.first?.memoryBytes == nil)
        #expect(rows.first?.cpuTimeNanos == nil)
    }
}
