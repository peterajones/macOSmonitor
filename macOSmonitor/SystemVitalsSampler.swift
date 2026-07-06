import Foundation

protocol SystemVitalsSampling: Sendable {
    func sample() async -> SystemVitals
}

/// Assembles a `SystemVitals` each tick: CPU% from host tick deltas (self-normalizing,
/// no wall clock), memory from the host shim, and the rest from `ProcessInfo`. Actor so
/// the syscalls run off the main thread; holds the previous CPU ticks for the delta.
actor SystemVitalsSampler: SystemVitalsSampling {
    private let host: any HostStatsProviding
    private var previousTicks: (busy: UInt64, total: UInt64)?

    init(host: any HostStatsProviding = HostStats()) {
        self.host = host
    }

    func sample() -> SystemVitals {
        var cpuPercent = 0.0
        if let ticks = host.cpuTicks() {
            // Require both counters to be monotonic before subtracting: per-core 32-bit
            // tick counters can wrap on extreme uptime, and an unguarded UInt64 subtraction
            // would trap. If either counter went backwards, skip this tick (0%).
            if let previous = previousTicks,
               ticks.total > previous.total, ticks.busy >= previous.busy {
                let deltaBusy = ticks.busy - previous.busy
                let deltaTotal = ticks.total - previous.total
                if deltaTotal > 0 { cpuPercent = 100.0 * Double(deltaBusy) / Double(deltaTotal) }
            }
            previousTicks = ticks
        }

        let info = ProcessInfo.processInfo
        let memory = host.memory()
        let version = info.operatingSystemVersion

        return SystemVitals(
            cpuUsagePercent: cpuPercent,
            usedMemoryBytes: memory?.used ?? 0,
            totalMemoryBytes: memory?.total ?? info.physicalMemory,
            coreCount: info.processorCount,
            activeCoreCount: info.activeProcessorCount,
            thermalState: Self.thermalName(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled,
            uptime: info.systemUptime,
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)"
        )
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
