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

    /// Cumulative user+system CPU time, or "—" when unreadable. Adaptive format:
    /// M:SS.ss under an hour, H:MM:SS at/beyond an hour (matches Activity Monitor).
    var cpuTimeText: String {
        guard let nanos = cpuTimeNanos else { return "—" }
        // Round to hundredths ONCE, then decompose with integer math so fractional
        // rounding can never push the seconds field to 60 (e.g. avoid "1:60.00").
        let totalCentiseconds = Int((Double(nanos) / 10_000_000).rounded())
        let totalSeconds = totalCentiseconds / 100
        if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let centisInMinute = totalCentiseconds - minutes * 6000
            return String(format: "%d:%02d.%02d", minutes, centisInMinute / 100, centisInMinute % 100)
        } else {
            return String(format: "%d:%02d:%02d",
                          totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
        }
    }

    var cpuTimeSortKey: UInt64 { cpuTimeNanos ?? 0 }

    /// Case-insensitive substring match against name or PID. Empty/whitespace → matches all.
    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return name.range(of: trimmed, options: .caseInsensitive) != nil
            || String(pid).contains(trimmed)
    }

    /// CPU% formatted for display, or an em dash when detail is unavailable.
    var cpuText: String { cpuPercent.map { String(format: "%.1f", $0) } ?? "—" }

    /// Resident memory formatted for display, or an em dash when detail is unavailable.
    var memoryText: String {
        memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—"
    }
}
