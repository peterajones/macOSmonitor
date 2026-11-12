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
