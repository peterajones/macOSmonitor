import Foundation
import Darwin
import Darwin.Mach

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
    var networkInBytesPerSec: Double = 0
    var networkOutBytesPerSec: Double = 0
    var networkInterfaces: [InterfaceRate] = []
    var battery: BatteryInfo? = nil
    var perCoreUsagePercent: [Double] = []
    var diskReadBytesPerSec: Double = 0
    var diskWriteBytesPerSec: Double = 0
    var memoryReading: MemoryReading? = nil
    var swap: SwapUsage? = nil
    var memoryPressure: MemoryPressure? = nil

    var cpuText: String { "\(Int(cpuUsagePercent.rounded()))%" }

    var memoryText: String {
        let usedGB = Double(usedMemoryBytes) / SystemVitals.bytesPerGB
        let totalGB = Double(totalMemoryBytes) / SystemVitals.bytesPerGB
        return String(format: "%.1f / %.0f GB", usedGB, totalGB)
    }

    /// Everything not counted as used, so the two always sum to total.
    var availableMemoryBytes: UInt64? {
        memoryReading.map { $0.total > $0.used ? $0.total - $0.used : 0 }
    }

    var memoryUsedFraction: Double {
        totalMemoryBytes > 0 ? Double(usedMemoryBytes) / Double(totalMemoryBytes) : 0
    }

    var memoryPercentText: String {
        totalMemoryBytes > 0 ? String(format: "%.1f%%", memoryUsedFraction * 100) : "—"
    }

    var usedMemoryText: String { (memoryReading?.used).map(SystemVitals.gigabytes) ?? "—" }
    var wiredMemoryText: String { (memoryReading?.wired).map(SystemVitals.gigabytes) ?? "—" }
    var compressedMemoryText: String { (memoryReading?.compressed).map(SystemVitals.gigabytes) ?? "—" }
    var appMemoryText: String { (memoryReading?.app).map(SystemVitals.gigabytes) ?? "—" }
    var pageInsText: String { memoryReading?.pageIns.formatted() ?? "—" }
    var pageOutsText: String { memoryReading?.pageOuts.formatted() ?? "—" }

    var cachedMemoryText: String { (memoryReading?.cached).map(SystemVitals.gigabytes) ?? "—" }
    var availableMemoryText: String { availableMemoryBytes.map(SystemVitals.gigabytes) ?? "—" }

    var swapText: String {
        guard let swap else { return "—" }
        return String(format: "%.1f / %.1f GB",
                      Double(swap.used) / SystemVitals.bytesPerGB,
                      Double(swap.total) / SystemVitals.bytesPerGB)
    }

    var memoryPressureText: String { memoryPressure?.rawValue ?? "—" }

    var uptimeText: String {
        let s = Int(uptime)
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Memory is reported in binary units so an 18 GB Mac reads as 18 GB. Network and
    /// disk rates stay decimal, as `rate(_:)` shows.
    private static let bytesPerGB: Double = 1_073_741_824

    static func gigabytes(_ bytes: UInt64) -> String { gigabytes(Double(bytes)) }

    static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / bytesPerGB)
    }

    /// e.g. "↓ 1.2 MB/s  ↑ 340 KB/s" (adaptive, decimal units).
    var networkText: String {
        "↓ \(SystemVitals.rate(networkInBytesPerSec))  ↑ \(SystemVitals.rate(networkOutBytesPerSec))"
    }

    /// e.g. "R 750 KB/s  W 0 B/s" (adaptive, decimal units).
    var diskText: String {
        "R \(SystemVitals.rate(diskReadBytesPerSec))  W \(SystemVitals.rate(diskWriteBytesPerSec))"
    }

    /// The one adaptive byte-rate formatter. Every rate string in the app routes
    /// through here so a 340 KB/s reading never renders as "0.3 MB/s" in one
    /// place and "340 KB/s" in another.
    static func rate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        if b < 1_000 { return String(format: "%.0f B/s", b) }
        if b < 1_000_000 { return String(format: "%.0f KB/s", b / 1_000) }
        if b < 1_000_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        return String(format: "%.1f GB/s", b / 1_000_000_000)
    }
}

/// One consistent read of the host's memory counters, in bytes (page counts for paging).
struct MemoryReading: Equatable, Sendable {
    let used: UInt64
    let total: UInt64
    var cached: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var app: UInt64 = 0
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
}

struct SwapUsage: Equatable, Sendable {
    let used: UInt64
    let total: UInt64
}

enum MemoryPressure: String, Sendable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"

    /// Maps `kern.memorystatus_vm_pressure_level`, which reports the dispatch
    /// memory-pressure constants: 1 normal, 2 warning, 4 critical.
    init?(kernelLevel: Int32) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }
}

/// One logical core's cumulative CPU tick counters.
struct CoreTicks: Equatable, Sendable {
    let busy: UInt64
    let total: UInt64
}

/// Raw host CPU/memory reads, isolated behind a protocol so the sampler can be tested with a fake.
protocol HostStatsProviding: Sendable {
    /// One entry per logical core. The aggregate is derived by summing, so this is
    /// deliberately the only CPU read — two calls per tick would be a wasted syscall
    /// and two inconsistent snapshots.
    func cpuTicks() -> [CoreTicks]?
    func memory() -> MemoryReading?
    func swapUsage() -> SwapUsage?
    func memoryPressureLevel() -> Int32?
}

struct HostStats: HostStatsProviding {
    func cpuTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(cpuCount))
        info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(cpuCount)) { ptr in
            for i in 0..<Int(cpuCount) {
                let t = ptr[i].cpu_ticks          // (user, system, idle, nice)
                let active = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
                cores.append(CoreTicks(busy: active, total: active + UInt64(t.2)))
            }
        }
        return cores
    }

    func swapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(used: usage.xsu_used, total: usage.xsu_total)
    }

    func memoryPressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        return level
    }

    func memory() -> MemoryReading? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // getpagesize(), not the C global vm_page_size: Swift 6 rejects reading a mutable
        // C global as unsafe shared state. Both are 16 KB on Apple Silicon.
        let page = UInt64(getpagesize())
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        // "Cached" is file-backed memory, which the system can drop and re-read from disk.
        let cached = UInt64(stats.external_page_count) * page
        // "App" memory is anonymous pages less the purgeable ones the system can discard.
        let app = UInt64(stats.internal_page_count) > UInt64(stats.purgeable_count)
            ? (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * page
            : 0
        return MemoryReading(used: used, total: ProcessInfo.processInfo.physicalMemory, cached: cached,
                             wired: UInt64(stats.wire_count) * page,
                             compressed: UInt64(stats.compressor_page_count) * page,
                             app: app,
                             pageIns: UInt64(stats.pageins),
                             pageOuts: UInt64(stats.pageouts))
    }
}
