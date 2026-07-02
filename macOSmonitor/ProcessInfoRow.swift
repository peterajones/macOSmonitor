import Darwin

/// One row of the process table. `cpuPercent`/`memoryBytes` are optional so a
/// denied (EPERM) or not-yet-baselined process is represented truthfully
/// rather than with a fake zero.
struct ProcessInfoRow: Identifiable, Hashable, Sendable {
    let pid: pid_t
    let name: String
    var cpuPercent: Double?
    var memoryBytes: UInt64?

    var id: pid_t { pid }

    /// Non-optional keys so `Table` columns can sort; missing detail sinks to the bottom.
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memSortKey: UInt64 { memoryBytes ?? 0 }

    /// True when we could read this process's task info, which under the same euid
    /// ownership check means we can also signal it. Drives enabling of Quit/Force Quit.
    var canTerminate: Bool { memoryBytes != nil }
}
