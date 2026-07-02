import Darwin
import Foundation

/// One finished per-process sample. `cpuTimeNanos` is total (user + system) CPU
/// time already converted from Mach ticks to nanoseconds.
struct ProcTaskSample: Sendable {
    let residentBytes: UInt64
    let cpuTimeNanos: UInt64
}

/// Everything unsafe/C lives behind this protocol so `ProcessSampler` can be
/// tested with a fake and no other file touches raw syscalls.
protocol ProcInfoProviding: Sendable {
    func listPIDs() -> [pid_t]
    func sample(pid: pid_t) -> ProcTaskSample?
    func name(pid: pid_t) -> String
}

struct ProcInfo: ProcInfoProviding {
    // mach_timebase is constant for the life of the process; capture it once.
    // pti CPU times come back in Mach "ticks"; nanos = ticks * numer / denom.
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// All PIDs on the system. Enumeration is unprivileged, so this returns
    /// every process regardless of owner.
    func listPIDs() -> [pid_t] {
        // First call with a nil buffer asks the kernel how many bytes we need.
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        // Second call actually fills the buffer.
        let written = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.stride
        return Array(pids.prefix(count).filter { $0 != 0 })
    }

    /// CPU time + resident memory for one process. Returns `nil` when the kernel
    /// denies us (EPERM — a process we don't own) or the process has exited.
    func sample(pid: pid_t) -> ProcTaskSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        // proc_pidinfo returns `size` on success; 0/negative on EPERM or vanished PID.
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        let nanos = ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return ProcTaskSample(residentBytes: info.pti_resident_size, cpuTimeNanos: nanos)
    }

    /// Best-effort process name. `proc_name` reads the BSD "comm" field, which is
    /// generally available even for other users' processes (unlike task info).
    func name(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 { return String(cString: buffer) }
        return "(pid \(pid))"
    }
}
