import Foundation

protocol SystemVitalsSampling: Sendable {
    func sample() async -> SystemVitals
}

/// Assembles a `SystemVitals` each tick: CPU% from host tick deltas (self-normalizing,
/// no wall clock), memory from the host shim, and the rest from `ProcessInfo`. Actor so
/// the syscalls run off the main thread; holds the previous CPU ticks for the delta.
actor SystemVitalsSampler: SystemVitalsSampling {
    private let host: any HostStatsProviding
    private let network: any NetworkStatsProviding
    private let battery: any BatteryStatsProviding
    private let now: @Sendable () -> UInt64
    private var previousCores: [CoreTicks]?
    private var previousCounters: (received: UInt64, sent: UInt64)?
    private var previousTime: UInt64?

    init(host: any HostStatsProviding = HostStats(),
         network: any NetworkStatsProviding = NetworkStats(),
         battery: any BatteryStatsProviding = BatteryStats(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.host = host
        self.network = network
        self.battery = battery
        self.now = now
    }

    func sample() -> SystemVitals {
        var cpuPercent = 0.0
        var perCore: [Double] = []
        if let cores = host.cpuTicks() {
            // Require both counters to be monotonic per core before subtracting: 32-bit
            // tick counters can wrap on extreme uptime, and an unguarded UInt64 subtraction
            // would trap. A wrapped core reports 0% and is excluded from the aggregate;
            // its neighbours are unaffected.
            if let previous = previousCores, previous.count == cores.count {
                var totalBusy: UInt64 = 0
                var totalAll: UInt64 = 0
                for (current, prior) in zip(cores, previous) {
                    guard current.total > prior.total, current.busy >= prior.busy else {
                        perCore.append(0)
                        continue
                    }
                    let deltaBusy = current.busy - prior.busy
                    let deltaTotal = current.total - prior.total
                    perCore.append(100.0 * Double(deltaBusy) / Double(deltaTotal))
                    totalBusy += deltaBusy
                    totalAll += deltaTotal
                }
                if totalAll > 0 { cpuPercent = 100.0 * Double(totalBusy) / Double(totalAll) }
            } else {
                // First tick, or the core count changed: no baseline to subtract from.
                perCore = Array(repeating: 0, count: cores.count)
            }
            previousCores = cores
        }

        var networkIn = 0.0
        var networkOut = 0.0
        if let counters = network.counters() {
            let time = now()
            if let previous = previousCounters, let previousT = previousTime, time > previousT {
                let seconds = Double(time - previousT) / 1_000_000_000
                if seconds > 0 {
                    if counters.received >= previous.received {
                        networkIn = Double(counters.received - previous.received) / seconds
                    }
                    if counters.sent >= previous.sent {
                        networkOut = Double(counters.sent - previous.sent) / seconds
                    }
                }
            }
            previousCounters = counters
            previousTime = time
        }

        let info = ProcessInfo.processInfo
        let memory = host.memory()
        let version = info.operatingSystemVersion
        let batteryInfo = battery.read()

        return SystemVitals(
            cpuUsagePercent: cpuPercent,
            usedMemoryBytes: memory?.used ?? 0,
            totalMemoryBytes: memory?.total ?? info.physicalMemory,
            coreCount: info.processorCount,
            activeCoreCount: info.activeProcessorCount,
            thermalState: Self.thermalName(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled,
            uptime: info.systemUptime,
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)",
            networkInBytesPerSec: networkIn,
            networkOutBytesPerSec: networkOut,
            battery: batteryInfo,
            perCoreUsagePercent: perCore
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
