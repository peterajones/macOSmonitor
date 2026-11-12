import Testing
import Darwin
import Foundation
@testable import macOSmonitor

final class FakeThreadProvider: ProcessThreadProviding, @unchecked Sendable {
    var result: [ThreadInfo]?
    func threads(pid: pid_t) -> [ThreadInfo]? { result }
}

struct ThreadInfoTests {
    @Test func busiestFirstWithStableTies() {
        let threads = [ThreadInfo(id: 9, name: "b", cpuTimeNanos: 5, cpuPercent: 0),
                       ThreadInfo(id: 3, name: "a", cpuTimeNanos: 5, cpuPercent: 0),
                       ThreadInfo(id: 1, name: "main", cpuTimeNanos: 90, cpuPercent: 0)]
        #expect(ThreadInfo.sortedForDisplay(threads).map(\.id) == [1, 3, 9])
    }

    @Test func unnamedThreadsShowTheirID() {
        #expect(ThreadInfo(id: 4242, name: "", cpuTimeNanos: 0, cpuPercent: 0).displayName == "thread 4242")
        #expect(ThreadInfo(id: 1, name: "main", cpuTimeNanos: 0, cpuPercent: 0).displayName == "main")
    }

    /// Integration: a named thread in this process burns ~150 ms of CPU and is reported with
    /// about that much time. Treating these nanoseconds as Mach ticks (or the reverse) would be
    /// off by ~40× on Apple silicon.
    @Test func reportsANamedBusyThreadsRealCPUTime() async throws {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            // The kernel name the inspector reads is set from inside the thread; Foundation's
            // Thread.name, set before start(), doesn't reach it.
            pthread_setname_np("mom-busy-test")
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start < 150_000_000 {}
            done.wait()                                   // stay alive until measured
        }
        thread.start()
        defer { done.signal() }

        var found: ThreadInfo?
        for _ in 0..<40 {
            found = ProcInfo().threads(pid: getpid())?.first { $0.name == "mom-busy-test" }
            if (found?.cpuTimeNanos ?? 0) >= 150_000_000 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let busy = try #require(found)
        #expect((150_000_000...1_000_000_000).contains(busy.cpuTimeNanos), "\(busy.cpuTimeNanos) ns")

        // Every thread's time together can't exceed the whole process's (task totals include
        // threads that already ended, so it may be less).
        let all = try #require(ProcInfo().threads(pid: getpid()))
        let task = try #require(ProcInfo().sample(pid: getpid())).cpuTimeNanos
        #expect(all.reduce(0) { $0 + $1.cpuTimeNanos } <= task + 50_000_000)
    }

    /// More threads than the first 256-entry buffer: the list must grow, not truncate.
    @Test func listsEveryThreadPastTheFirstBuffer() throws {
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        for _ in 0..<300 {
            Thread { started.signal(); release.wait() }.start()
        }
        defer { for _ in 0..<300 { release.signal() } }
        for _ in 0..<300 { started.wait() }

        let count = try #require(ProcInfo().threads(pid: getpid())).count
        #expect(count >= 300, "only \(count) threads listed")
    }

    @Test(.enabled(if: getuid() != 0))
    func deniedForRootsProcesses() {
        #expect(ProcInfo().threads(pid: 1) == nil)
    }
}

@MainActor
struct ThreadsModelTests {
    @Test func publishesThreadsBusiestFirstAndCollapsesOnSelectionChange() {
        let fake = FakeThreadProvider()
        fake.result = [ThreadInfo(id: 2, name: "worker", cpuTimeNanos: 1, cpuPercent: 0),
                       ThreadInfo(id: 1, name: "main", cpuTimeNanos: 9, cpuPercent: 0)]
        let model = ProcessListModel(sampler: FakeSampler(), threadProvider: fake)

        model.selectedPID = 5
        model.refreshSelection()
        #expect(model.selectedThreads?.map(\.name) == ["main", "worker"])

        model.isThreadsExpanded = true
        model.selectedPID = 5
        #expect(model.isThreadsExpanded)
        model.selectedPID = 6
        #expect(!model.isThreadsExpanded)

        fake.result = nil                                  // denied
        model.refreshSelection()
        #expect(model.selectedThreads == nil)
    }
}
