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
    var battery: BatteryInfo? = nil
    var perCoreUsagePercent: [Double] = []
    var diskReadBytesPerSec: Double = 0
    var diskWriteBytesPerSec: Double = 0

    var cpuText: String { "\(Int(cpuUsagePercent.rounded()))%" }

    var memoryText: String {
        let usedGB = Double(usedMemoryBytes) / 1_000_000_000
        let totalGB = Double(totalMemoryBytes) / 1_000_000_000
        return String(format: "%.1f / %.0f GB", usedGB, totalGB)
    }

    var uptimeText: String {
        let s = Int(uptime)
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// e.g. "↓ 1.2 MB/s  ↑ 340 KB/s" (adaptive, decimal units).
    var networkText: String {
        "↓ \(SystemVitals.rate(networkInBytesPerSec))  ↑ \(SystemVitals.rate(networkOutBytesPerSec))"
    }

    private static func rate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        if b < 1_000 { return String(format: "%.0f B/s", b) }
        if b < 1_000_000 { return String(format: "%.0f KB/s", b / 1_000) }
        if b < 1_000_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        return String(format: "%.1f GB/s", b / 1_000_000_000)
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
    func memory() -> (used: UInt64, total: UInt64)?
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

    func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }
}
