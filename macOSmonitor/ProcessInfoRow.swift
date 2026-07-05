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

    var id: pid_t { pid }

    /// Non-optional keys so `Table` columns can sort; missing detail sinks to the bottom.
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memSortKey: UInt64 { memoryBytes ?? 0 }

    /// True when we could read this process's task info, which under the same euid
    /// ownership check means we can also signal it. Drives enabling of Quit/Force Quit.
    var canTerminate: Bool { memoryBytes != nil }

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
