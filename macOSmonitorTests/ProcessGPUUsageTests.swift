import Testing
import Foundation
@testable import macOSmonitor

final class FakeGPUUsage: ProcessGPUUsageProviding, @unchecked Sendable {
    var next: [pid_t: UInt64]?
    func gpuTimes() -> [pid_t: UInt64]? { next }
}

struct ProcessGPUUsageTests {
    @Test func parsesTheCreatorPID() {
        #expect(GPUClientParsing.pid(fromCreator: "pid 625, WindowServer") == 625)
        #expect(GPUClientParsing.pid(fromCreator: "pid 12") == 12)
        #expect(GPUClientParsing.pid(fromCreator: "WindowServer") == nil)
        #expect(GPUClientParsing.pid(fromCreator: "pid x, y") == nil)
        #expect(GPUClientParsing.pid(fromCreator: "uid 501, pjones") == nil)   // a number, but not a pid
    }

    @Test func sumsEveryAPIsGPUTime() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 1_916_239_395_958 as UInt64)],
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 35_117_875 as UInt64)],
            ["API": "OpenGL"],                                              // no counter: ignored
        ]
        #expect(GPUClientParsing.gpuTime(fromAppUsage: usage) == 1_916_274_513_833)
    }

    private func sampler(_ gpu: FakeGPUUsage, _ clock: FakeClock) -> ProcessSampler {
        let source = FakeProcInfo()
        source.pids = [42, 43]
        source.results = [42: ProcTaskSample(residentBytes: 1, cpuTimeNanos: 0),
                          43: ProcTaskSample(residentBytes: 1, cpuTimeNanos: 0)]
        return ProcessSampler(source: source, apps: FakeRegularApps(), gpu: gpu, now: { clock.now })
    }

    /// 42 used 0.25 s of GPU in a 0.5 s interval: 50%. A version dividing by a fixed second,
    /// or reporting the cumulative time, gives a visibly different figure.
    @Test func gpuPercentIsTheShareOfTheInterval() async {
        let gpu = FakeGPUUsage(), clock = FakeClock()
        let sampler = sampler(gpu, clock)

        gpu.next = [42: 1_000_000_000]
        clock.now = 10_000_000_000
        let first = await sampler.sample()
        #expect(first.map(\.gpuPercent) == [nil, nil])               // no baseline yet
        #expect(first.map(\.gpuTimeNanos) == [1_000_000_000, 0])

        gpu.next = [42: 1_250_000_000]
        clock.now = 10_500_000_000
        let second = await sampler.sample()
        #expect(second.map(\.gpuPercent) == [50, 0])                  // 43 used no GPU: 0, not "—"
        #expect(second.first?.gpuText == "50.0")
    }

    /// A summed counter can drop when one of a process's GPU clients closes.
    @Test func aDroppingCounterReadsZeroRatherThanTrapping() async {
        let gpu = FakeGPUUsage(), clock = FakeClock()
        let sampler = sampler(gpu, clock)
        gpu.next = [42: 5_000_000_000]; clock.now = 1_000_000_000
        _ = await sampler.sample()
        gpu.next = [42: 1_000_000_000]; clock.now = 2_000_000_000
        #expect(await sampler.sample().first?.gpuPercent == 0)
    }

    @Test func unreadableGPUUsageShowsADashForEveryRow() async {
        let gpu = FakeGPUUsage(), clock = FakeClock()
        let sampler = sampler(gpu, clock)
        gpu.next = nil
        _ = await sampler.sample()
        clock.now = 1_000_000_000
        let rows = await sampler.sample()
        #expect(rows.map(\.gpuText) == ["—", "—"])
        #expect(rows.map(\.gpuSortKey) == [-1, -1])
    }

    /// Integration: WindowServer always draws with the GPU, and its time is readable without root.
    @Test(.enabled(if: ProcessGPUUsage().gpuTimes() != nil))
    func readsThisMacsPerProcessGPUTime() throws {
        let times = try #require(ProcessGPUUsage().gpuTimes())
        // By path: proc_name is denied for WindowServer, so its name can't be used to find it.
        let windowServer = try #require(ProcInfo().listPIDs().first {
            ProcInfo().path(pid: $0)?.hasSuffix("/WindowServer") == true
        })
        #expect((times[windowServer] ?? 0) > 0)
    }
}
