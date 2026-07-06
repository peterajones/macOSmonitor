import Foundation

/// A snapshot of system-wide vitals shown in the header bar.
struct SystemVitals: Equatable, Sendable {
    let cpuUsagePercent: Double
    let usedMemoryBytes: UInt64
    let totalMemoryBytes: UInt64
    let coreCount: Int
    let activeCoreCount: Int
    let thermalState: String     // "Nominal" / "Fair" / "Serious" / "Critical"
    let lowPowerMode: Bool
    let uptime: TimeInterval
    let osVersion: String        // e.g. "macOS 26.5"

    var cpuText: String { "CPU \(Int(cpuUsagePercent.rounded()))%" }

    var memoryText: String {
        let usedGB = Double(usedMemoryBytes) / 1_000_000_000
        let totalGB = Double(totalMemoryBytes) / 1_000_000_000
        return String(format: "%.1f / %.0f GB", usedGB, totalGB)
    }

    var coresText: String { "\(coreCount) cores" }

    var uptimeText: String {
        let s = Int(uptime)
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "up \(d)d \(h)h" }
        if h > 0 { return "up \(h)h \(m)m" }
        return "up \(m)m"
    }
}
