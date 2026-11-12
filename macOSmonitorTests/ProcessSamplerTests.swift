import Testing
import Darwin
@testable import macOSmonitor

/// Scriptable stand-in for ProcInfo. Mutate `results` between `sample()` calls
/// to simulate successive ticks.
final class FakeProcInfo: ProcInfoProviding, @unchecked Sendable {
    var pids: [pid_t] = []
    var names: [pid_t: String] = [:]
    var results: [pid_t: ProcTaskSample] = [:]
    var owners: [pid_t: uid_t] = [:]
    var paths: [pid_t: String] = [:]
    func path(pid: pid_t) -> String? { paths[pid] }
    func listPIDs() -> [pid_t] { pids }
    func owner(pid: pid_t) -> uid_t? { owners[pid] }
    func sample(pid: pid_t) -> ProcTaskSample? { results[pid] }
    func name(pid: pid_t) -> String { names[pid] ?? "(pid \(pid))" }
}

final class FakeRegularApps: RegularAppProviding, @unchecked Sendable {
    var pids: Set<pid_t> = []
    func regularAppPIDs() -> Set<pid_t> { pids }
}

struct ProcessSamplerTests {
    @Test func onlyRegularAppPIDsAreMarkedAsApplications() async {
        let fake = FakeProcInfo()
        fake.pids = [42, 43]; fake.names = [42: "app", 43: "daemon"]
        fake.results = [42: ProcTaskSample(residentBytes: 1, cpuTimeNanos: 0),
                        43: ProcTaskSample(residentBytes: 1, cpuTimeNanos: 0)]
        let apps = FakeRegularApps()
        apps.pids = [42]
        let sampler = ProcessSampler(source: fake, apps: apps, now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.map(\.isApplication) == [true, false])
    }

    /// The owner is carried on denied rows too: those are mostly the system processes the
    /// Hide System Processes switch exists for.
    @Test func ownerIsCarriedOnReadableAndDeniedRows() async {
        let fake = FakeProcInfo()
        fake.pids = [42, 43]
        fake.results = [42: ProcTaskSample(residentBytes: 1, cpuTimeNanos: 0)]
        fake.owners = [42: 501, 43: 262]
        let sampler = ProcessSampler(source: fake, apps: FakeRegularApps(), now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.map(\.uid) == [501, 262])
    }

    @Test func deniedRegularAppIsStillMarkedAsApplication() async {
        let fake = FakeProcInfo()
        fake.pids = [7]; fake.names = [7: "other-user-app"]
        let apps = FakeRegularApps()
        apps.pids = [7]
        let sampler = ProcessSampler(source: fake, apps: apps, now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.first?.isApplication == true)
    }

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
