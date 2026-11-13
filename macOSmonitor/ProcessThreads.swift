import Darwin

/// One thread of a process, for the inspector.
struct ThreadInfo: Equatable, Sendable, Identifiable, Codable {
    let id: UInt64
    let name: String
    /// Cumulative user + system CPU time in nanoseconds. Unlike `proc_taskinfo`'s totals,
    /// which are Mach ticks, `proc_threadinfo` reports nanoseconds already.
    let cpuTimeNanos: UInt64
    /// Recent CPU usage, 0–100% of one core.
    let cpuPercent: Double

    /// The name, or "thread <id>" for the many threads that never set one.
    var displayName: String { name.isEmpty ? "thread \(id)" : name }

    /// Busiest first by CPU time; ties by id, so the list doesn't reshuffle every tick.
    static func sortedForDisplay(_ threads: [ThreadInfo]) -> [ThreadInfo] {
        threads.sorted { $0.cpuTimeNanos == $1.cpuTimeNanos ? $0.id < $1.id : $0.cpuTimeNanos > $1.cpuTimeNanos }
    }
}

/// Lists a process's threads; behind a protocol so the model can be tested with a fake.
protocol ProcessThreadProviding: Sendable {
    /// Nil when denied (another user's process) or exited.
    func threads(pid: pid_t) -> [ThreadInfo]?
}

extension ProcInfo: ProcessThreadProviding {
    func threads(pid: pid_t) -> [ThreadInfo]? {
        guard let ids = threadIDs(pid: pid) else { return nil }
        return ids.compactMap { id in
            var info = proc_threadinfo()
            let size = Int32(MemoryLayout<proc_threadinfo>.size)
            // A thread that ended since the list was taken just drops out.
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &info, size) == size else { return nil }
            let name = withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return ThreadInfo(id: id, name: name,
                              cpuTimeNanos: info.pth_user_time &+ info.pth_system_time,
                              cpuPercent: Double(info.pth_cpu_usage) / Double(TH_USAGE_SCALE) * 100)
        }
    }

    /// The process's thread handles, or nil when denied. Unlike the other flavours, a
    /// nil-buffer size query for PROC_PIDLISTTHREADS returns 0, so instead read into a buffer
    /// and double it until the list fits with room to spare (a full buffer may be truncated).
    private func threadIDs(pid: pid_t) -> [UInt64]? {
        var capacity = 256
        while capacity <= 65_536 {
            var ids = [UInt64](repeating: 0, count: capacity)
            let written = ids.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, $0.baseAddress, Int32($0.count))
            }
            guard written > 0 else { return nil }
            let count = Int(written) / MemoryLayout<UInt64>.stride
            if count < capacity { return Array(ids.prefix(count)) }
            capacity *= 2
        }
        return nil
    }
}
