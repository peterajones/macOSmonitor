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
    private let disk: any DiskStatsProviding
    private let now: @Sendable () -> UInt64
    private var previousCores: [CoreTicks]?
    private var previousInterfaces: [String: InterfaceCounters] = [:]
    private var previousInterfaceNames: Set<String>?
    private var hardwarePorts: [String: HardwarePort] = [:]
    private var previousTime: UInt64?
    private var previousDiskCounters: (read: UInt64, written: UInt64)?
    private var previousDiskTime: UInt64?

    init(host: any HostStatsProviding = HostStats(),
         network: any NetworkStatsProviding = NetworkStats(),
         battery: any BatteryStatsProviding = BatteryStats(),
         disk: any DiskStatsProviding = DiskStats(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.host = host
        self.network = network
        self.battery = battery
        self.disk = disk
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
        var networkInterfaces: [InterfaceRate] = []
        if let interfaces = network.interfaceCounters() {
            let time = now()
            // Rates per interface, each guarded on its own: one interface resetting (or one
            // just plugged in, with no baseline) reports 0 without zeroing its neighbours.
            var rates: [String: (in: Double, out: Double)] = [:]
            if let previousT = previousTime, time > previousT {
                let seconds = Double(time - previousT) / 1_000_000_000
                for current in interfaces {
                    guard let prior = previousInterfaces[current.name] else { continue }
                    let rateIn = current.received >= prior.received
                        ? Double(current.received - prior.received) / seconds : 0
                    let rateOut = current.sent >= prior.sent
                        ? Double(current.sent - prior.sent) / seconds : 0
                    rates[current.name] = (in: rateIn, out: rateOut)
                    networkIn += rateIn
                    networkOut += rateOut
                }
            }

            // Port names only change when hardware comes or goes, and the lookup is costly.
            let names = Set(interfaces.map(\.name))
            if names != previousInterfaceNames {
                hardwarePorts = network.hardwarePorts()
                previousInterfaceNames = names
            }
            networkInterfaces = NetworkBreakdown.rows(counters: interfaces, rates: rates,
                                                      ports: hardwarePorts)

            previousInterfaces = Dictionary(interfaces.map { ($0.name, $0) },
                                            uniquingKeysWith: { first, _ in first })
            previousTime = time
        }

        var diskRead = 0.0
        var diskWrite = 0.0
        if let counters = disk.counters() {
            let time = now()
            if let previous = previousDiskCounters, let previousT = previousDiskTime,
               time > previousT {
                let seconds = Double(time - previousT) / 1_000_000_000
                if seconds > 0 {
                    if counters.read >= previous.read {
                        diskRead = Double(counters.read - previous.read) / seconds
                    }
                    if counters.written >= previous.written {
                        diskWrite = Double(counters.written - previous.written) / seconds
                    }
                }
            }
            previousDiskCounters = counters
            previousDiskTime = time
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
            networkInterfaces: networkInterfaces,
            battery: batteryInfo,
            perCoreUsagePercent: perCore,
            diskReadBytesPerSec: diskRead,
            diskWriteBytesPerSec: diskWrite,
            memoryReading: memory,
            swap: host.swapUsage(),
            memoryPressure: host.memoryPressureLevel().flatMap(MemoryPressure.init(kernelLevel:))
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
