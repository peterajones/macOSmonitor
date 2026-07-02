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
}
