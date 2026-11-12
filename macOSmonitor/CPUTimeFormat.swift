import Foundation

/// How cumulative CPU time is written in the process table and inspector. Chosen from
/// View ▸ CPU Time Format and remembered in `@AppStorage("cpuTimeFormat")`.
enum CPUTimeFormat: String, CaseIterable, Identifiable, Sendable {
    /// M:SS.ss under an hour, H:MM:SS from an hour (Activity Monitor's format).
    case adaptive
    /// Always H:MM:SS, so a column of mixed values lines up.
    case hours
    /// Total seconds with hundredths, e.g. "5025.00 s": easy to compare and to paste.
    case seconds
    /// Units spelled out, largest first: "3.03s", "2m 05s", "1h 23m 45s".
    case compact

    static let storageKey = "cpuTimeFormat"

    var id: Self { self }

    var title: String {
        switch self {
        case .adaptive: "Activity Monitor (2:05.37)"
        case .hours:    "Hours (0:02:05)"
        case .seconds:  "Seconds (125.37 s)"
        case .compact:  "Compact (2m 05s)"
        }
    }

    /// `nanos` written in this format, or "—" when unreadable.
    func string(nanos: UInt64?) -> String {
        guard let nanos else { return "—" }
        // Round to hundredths ONCE, then split with integer maths, so rounding can never
        // push a field to 60 (119.9996 s must read 2:00.00, never 1:60.00).
        let centis = Int((Double(nanos) / 10_000_000).rounded())
        let seconds = centis / 100
        let (h, m, s, cs) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60, centis % 100)

        switch self {
        case .adaptive:
            return seconds < 3600
                ? String(format: "%d:%02d.%02d", seconds / 60, s, cs)
                : String(format: "%d:%02d:%02d", h, m, s)
        case .hours:
            return String(format: "%d:%02d:%02d", h, m, s)
        case .seconds:
            return String(format: "%d.%02d s", seconds, cs)
        case .compact:
            if seconds < 60 { return String(format: "%d.%02ds", s, cs) }
            if seconds < 3600 { return String(format: "%dm %02ds", m, s) }
            return String(format: "%dh %02dm %02ds", h, m, s)
        }
    }
}
