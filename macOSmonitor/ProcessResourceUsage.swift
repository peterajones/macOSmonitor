import Darwin
import Foundation

/// A process's cumulative disk I/O, energy and on-behalf-of CPU time, from `proc_pid_rusage`
/// (own processes only).
struct ProcessResourceUsage: Equatable, Sendable, Codable {
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
    /// The kernel's estimate of energy used, in nanojoules (`ri_energy_nj`). Not Activity
    /// Monitor's "Energy Impact", which is Apple's own undisclosed score.
    let energyNanojoules: UInt64
    /// CPU time other processes spent working for this one, billed to it by the kernel's
    /// voucher accounting (WindowServer drawing its windows, a daemon serving its request).
    var billedCPUNanos: UInt64 = 0
    /// CPU time this process spent working for others.
    var servicedCPUNanos: UInt64 = 0
}

/// Per-second rates between two readings of the same process.
struct ProcessUsageRates: Equatable, Sendable {
    let readBytesPerSec: Double
    let writeBytesPerSec: Double
    let watts: Double

    /// Rates from `previous` to `current` over `nanos`; nil without a positive interval.
    /// A counter that went backwards (it shouldn't, but unsigned subtraction would trap)
    /// reads 0.
    init?(from previous: ProcessResourceUsage, to current: ProcessResourceUsage, overNanos nanos: UInt64) {
        guard nanos > 0 else { return nil }
        let seconds = Double(nanos) / 1_000_000_000
        func delta(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) : 0 }
        readBytesPerSec = delta(previous.diskBytesRead, current.diskBytesRead) / seconds
        writeBytesPerSec = delta(previous.diskBytesWritten, current.diskBytesWritten) / seconds
        watts = delta(previous.energyNanojoules, current.energyNanojoules) / 1_000_000_000 / seconds
    }

    init(readBytesPerSec: Double, writeBytesPerSec: Double, watts: Double) {
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
        self.watts = watts
    }

    var powerText: String { String(format: "%.2f W", watts) }
}

extension ProcessResourceUsage {
    var readText: String { ByteCountFormatter.string(fromByteCount: Int64(clamping: diskBytesRead), countStyle: .file) }
    var writtenText: String { ByteCountFormatter.string(fromByteCount: Int64(clamping: diskBytesWritten), countStyle: .file) }
    /// "1.23 kJ", "456 J", "12.3 mJ".
    var energyText: String {
        let joules = Double(energyNanojoules) / 1_000_000_000
        if joules >= 1000 { return String(format: "%.2f kJ", joules / 1000) }
        if joules >= 1 { return String(format: "%.1f J", joules) }
        return String(format: "%.1f mJ", joules * 1000)
    }
}

/// Reads `ProcessResourceUsage`; behind a protocol so the model can be tested with a fake.
protocol ProcessResourceUsageProviding: Sendable {
    /// Nil when denied (another user's process) or exited.
    func usage(pid: pid_t) -> ProcessResourceUsage?
}

extension ProcInfo: ProcessResourceUsageProviding {
    func usage(pid: pid_t) -> ProcessResourceUsage? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return nil }
        // ri_*_time are Mach ticks, like proc_taskinfo's (ri_user_time equals pti_total_user).
        return ProcessResourceUsage(diskBytesRead: info.ri_diskio_bytesread,
                                    diskBytesWritten: info.ri_diskio_byteswritten,
                                    energyNanojoules: info.ri_energy_nj,
                                    billedCPUNanos: nanos(ticks: info.ri_billed_system_time),
                                    servicedCPUNanos: nanos(ticks: info.ri_serviced_system_time))
    }
}
