import Testing
import Darwin
import Foundation
@testable import macOSmonitor

final class FakeUsageProvider: ProcessResourceUsageProviding, @unchecked Sendable {
    var result: ProcessResourceUsage?
    func usage(pid: pid_t) -> ProcessResourceUsage? { result }
}

struct ProcessResourceUsageTests {
    /// Over half a second: 4 MB read → 8 MB/s; 1 MB written → 2 MB/s; 1.5 J → 3 W. A version
    /// that divided by a whole second, or by 1e6 for energy, gives visibly different numbers.
    @Test func ratesAreDeltasOverTheInterval() throws {
        let before = ProcessResourceUsage(diskBytesRead: 1_000_000, diskBytesWritten: 0, energyNanojoules: 500_000_000)
        let after = ProcessResourceUsage(diskBytesRead: 5_000_000, diskBytesWritten: 1_000_000, energyNanojoules: 2_000_000_000)
        let rates = try #require(ProcessUsageRates(from: before, to: after, overNanos: 500_000_000))
        #expect(rates.readBytesPerSec == 8_000_000)
        #expect(rates.writeBytesPerSec == 2_000_000)
        #expect(rates.watts == 3)
        #expect(rates.powerText == "3.00 W")
    }

    @Test func backwardsCountersAndZeroIntervalsAreSafe() {
        let high = ProcessResourceUsage(diskBytesRead: 9, diskBytesWritten: 9, energyNanojoules: 9)
        let low = ProcessResourceUsage(diskBytesRead: 1, diskBytesWritten: 1, energyNanojoules: 1)
        #expect(ProcessUsageRates(from: high, to: low, overNanos: 1_000_000_000)
                == ProcessUsageRates(readBytesPerSec: 0, writeBytesPerSec: 0, watts: 0))
        #expect(ProcessUsageRates(from: low, to: high, overNanos: 0) == nil)
    }

    /// Mach ticks to nanoseconds with this Mac's timebase; Apple Silicon's is 125/3.
    @Test func ticksConvertWithTheTimebase() {
        #expect(ProcInfo.nanos(ticks: 3_000, numer: 125, denom: 3) == 125_000)
        #expect(ProcInfo.nanos(ticks: 7, numer: 1, denom: 1) == 7)        // Intel: ticks are ns
    }

    /// Billed and serviced CPU time come from the same struct as `ri_user_time`, which is in
    /// Mach ticks (it equals `pti_total_user`), so they must be converted like CPU time.
    @Test func onBehalfOfTimesAreConvertedFromTicks() throws {
        var raw = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &raw) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        try #require(status == 0)
        let usage = try #require(ProcInfo().usage(pid: getpid()))
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // The counters only grow, so the reading taken second is at least the converted raw one,
        // and (within a few ms of each other) not wildly above it.
        let billed = ProcInfo.nanos(ticks: raw.ri_billed_system_time, numer: timebase.numer, denom: timebase.denom)
        let serviced = ProcInfo.nanos(ticks: raw.ri_serviced_system_time, numer: timebase.numer, denom: timebase.denom)
        #expect(usage.billedCPUNanos >= billed && usage.billedCPUNanos <= billed + 50_000_000)
        #expect(usage.servicedCPUNanos >= serviced && usage.servicedCPUNanos <= serviced + 50_000_000)
    }

    @Test func energyReadsInSensibleUnits() {
        func text(_ nj: UInt64) -> String { ProcessResourceUsage(diskBytesRead: 0, diskBytesWritten: 0, energyNanojoules: nj).energyText }
        #expect(text(12_300_000) == "12.3 mJ")
        #expect(text(456_000_000_000) == "456.0 J")
        #expect(text(1_234_000_000_000) == "1.23 kJ")
    }

    /// Integration: writing a 4 MB file shows up as bytes written by this process.
    @Test func countsThisProcesssDiskWrites() throws {
        let before = try #require(ProcInfo().usage(pid: getpid()))
        let url = FileManager.default.temporaryDirectory.appending(path: "mom-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 4_000_000).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)          // push it to disk now
        try handle.close()
        let after = try #require(ProcInfo().usage(pid: getpid()))
        #expect(after.diskBytesWritten - before.diskBytesWritten >= 4_000_000)
        #expect(after.energyNanojoules >= before.energyNanojoules)
    }

    @Test(.enabled(if: getuid() != 0))
    func deniedForRootsProcesses() {
        #expect(ProcInfo().usage(pid: 1) == nil)
    }
}

@MainActor
struct UsageModelTests {
    private final class Clock: @unchecked Sendable { var nanos: UInt64 = 1_000_000_000 }

    @Test func ratesStartOnTheSecondTickAndResetOnSelectionChange() {
        let usage = FakeUsageProvider(), clock = Clock()
        let model = ProcessListModel(sampler: FakeSampler(), usageProvider: usage, now: { clock.nanos })

        usage.result = ProcessResourceUsage(diskBytesRead: 0, diskBytesWritten: 0, energyNanojoules: 0)
        model.selectedPID = 7
        model.refreshSelection()
        #expect(model.selectedUsage != nil)
        #expect(model.selectedUsageRates == nil)                 // first tick: no baseline

        usage.result = ProcessResourceUsage(diskBytesRead: 2_000, diskBytesWritten: 0, energyNanojoules: 1_000_000_000)
        clock.nanos += 1_000_000_000
        model.refreshSelection()
        #expect(model.selectedUsageRates?.readBytesPerSec == 2_000)
        #expect(model.selectedUsageRates?.watts == 1)

        // Another process: its counters must not be measured against process 7's.
        usage.result = ProcessResourceUsage(diskBytesRead: 900_000, diskBytesWritten: 0, energyNanojoules: 0)
        model.selectedPID = 8
        clock.nanos += 1_000_000_000
        model.refreshSelection()
        #expect(model.selectedUsageRates == nil)

        usage.result = nil                                        // denied
        model.refreshSelection()
        #expect(model.selectedUsage == nil && model.selectedUsageRates == nil)
    }
}
