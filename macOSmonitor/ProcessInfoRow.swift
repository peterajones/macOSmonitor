import Darwin
import Foundation

/// One row of the process table. `cpuPercent`/`memoryBytes` are optional so a
/// denied (EPERM) or not-yet-baselined process is represented truthfully
/// rather than with a fake zero.
struct ProcessInfoRow: Identifiable, Hashable, Sendable {
    let pid: pid_t
    let name: String
    var cpuPercent: Double?
    var memoryBytes: UInt64?
    var cpuTimeNanos: UInt64? = nil
    var isApplication: Bool = false
    /// Owning user; nil when it couldn't be read (the process exited mid-sample).
    var uid: uid_t? = nil
    /// Owner's account name, for `user:` searches; nil when the owner is unknown.
    var user: String? = nil
    /// Executable path, for `path:` searches; nil when it couldn't be read.
    var path: String? = nil

    var id: pid_t { pid }

    /// Non-optional keys so `Table` columns can sort; missing detail sinks to the bottom.
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memSortKey: UInt64 { memoryBytes ?? 0 }

    /// True when we could read this process's task info, which under the same euid
    /// ownership check means we can also signal it. Drives enabling of Quit/Force Quit.
    var canTerminate: Bool { memoryBytes != nil }

    /// The `limit` highest-CPU rows, descending, ties broken by ascending PID.
    ///
    /// The tiebreak matters: Swift's `sorted` is not guaranteed stable and many
    /// processes sit at exactly 0%, so without it the list would reshuffle every tick.
    /// `cpuSortKey` is -1 for unreadable processes, sinking them below 0% ones.
    static func topByCPU(_ rows: [ProcessInfoRow], limit: Int) -> [ProcessInfoRow] {
        guard limit > 0 else { return [] }
        let sorted = rows.sorted {
            $0.cpuSortKey == $1.cpuSortKey ? $0.pid < $1.pid : $0.cpuSortKey > $1.cpuSortKey
        }
        return Array(sorted.prefix(limit))
    }

    /// Cumulative user+system CPU time in Activity Monitor's format, or "—" when unreadable.
    var cpuTimeText: String { cpuTimeText(.adaptive) }

    /// Cumulative user+system CPU time in `format`, or "—" when unreadable.
    func cpuTimeText(_ format: CPUTimeFormat) -> String {
        format.string(nanos: cpuTimeNanos)
    }

    var cpuTimeSortKey: UInt64 { cpuTimeNanos ?? 0 }

    /// Whether this row matches a search (see `ProcessQuery` for the syntax). Blank matches
    /// all. Parses on every call: when filtering many rows, parse one `ProcessQuery` instead.
    func matches(_ query: String) -> Bool {
        ProcessQuery(query).matches(self)
    }

    /// CPU% formatted for display, or an em dash when detail is unavailable.
    var cpuText: String { cpuPercent.map { String(format: "%.1f", $0) } ?? "—" }

    /// Resident memory formatted for display, or an em dash when detail is unavailable.
    var memoryText: String {
        memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—"
    }
}
