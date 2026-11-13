import Darwin
import Foundation

/// Everything unsafe/C lives behind this protocol so `ProcessSampler` can be
/// tested with a fake and no other file touches raw syscalls.
protocol ProcInfoProviding: Sendable {
    func listPIDs() -> [pid_t]
    func sample(pid: pid_t) -> ProcTaskSample?
    func name(pid: pid_t) -> String
    /// The owning user's uid, or nil when the process has exited.
    func owner(pid: pid_t) -> uid_t?
    /// The executable's path, or nil when it can't be read.
    func path(pid: pid_t) -> String?
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

    /// CPU time, resident memory and energy for one process. Returns `nil` when the kernel
    /// denies us (EPERM — a process we don't own) or the process has exited.
    func sample(pid: pid_t) -> ProcTaskSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        // proc_pidinfo returns `size` on success; 0/negative on EPERM or vanished PID.
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        return ProcTaskSample(residentBytes: info.pti_resident_size, cpuTimeNanos: nanos(ticks: ticks),
                              energyNanojoules: usage(pid: pid)?.energyNanojoules)
    }

    /// Mach ticks to nanoseconds with this Mac's timebase.
    func nanos(ticks: UInt64) -> UInt64 {
        Self.nanos(ticks: ticks, numer: timebase.numer, denom: timebase.denom)
    }

    /// `ticks * numer / denom`. Apple Silicon's timebase is 125/3; on Intel ticks are already ns.
    static func nanos(ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        ticks &* UInt64(numer) / UInt64(denom)
    }

    /// Best-effort process name. `proc_name` reads the BSD "comm" field, but macOS denies it
    /// for about a quarter of processes (WindowServer, installd, cloudd…) whose executable
    /// path is still readable, so those are named from the path rather than shown as "(pid N)".
    func name(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return Self.displayName(procName: length > 0 ? String(cBuffer: buffer) : nil,
                                path: length > 0 ? nil : path(pid: pid), pid: pid)
    }

    /// The name to show: `proc_name` when readable, else the executable's file name, else
    /// "(pid N)". Pure, so the fallback order is testable.
    static func displayName(procName: String?, path: String?, pid: pid_t) -> String {
        if let procName, !procName.isEmpty { return procName }
        if let file = path?.split(separator: "/").last, !file.isEmpty { return String(file) }
        return "(pid \(pid))"
    }

    /// Readable for every process, root's included, and cheap: ~1 ms for all ~800 per tick.
    func path(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE isn't Swift-visible; it's 4 * MAXPATHLEN.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cBuffer: buffer) : nil
    }

    /// The short BSD info is readable for every process, root's included (unlike task
    /// info), so ownership is known even for rows whose CPU and memory are denied.
    func owner(pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }
}
