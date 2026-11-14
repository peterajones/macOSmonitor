import Foundation

/// Six index-aligned sliding windows of system vitals, plus a longer memory window for
/// the Memory panel's compressed graph, fed one `SystemVitals` snapshot at a time.
/// No clock, no syscalls, no SwiftUI.
struct VitalsHistory: Equatable, Sendable {
    var cpu: MetricHistory
    /// The kernel's share of CPU time, alongside `cpu`.
    var cpuSystem: MetricHistory
    var memoryUsed: MetricHistory
    var networkIn: MetricHistory
    var networkOut: MetricHistory
    var diskRead: MetricHistory
    var diskWrite: MetricHistory
    var memoryUsedLong: MetricHistory
    /// GPU utilisation %; 0 for ticks where no GPU statistics were published.
    var gpu: MetricHistory
    /// One series per logical core, for the CPU panel's Logical Processors traces. Sized by
    /// the first sample that carries per-core data, and rebuilt if the core count changes.
    private(set) var perCore: [MetricHistory] = []
    private let capacity: Int

    static let longMemoryCapacity = 300

    init(capacity: Int = 60) {
        self.capacity = capacity
        cpu = MetricHistory(capacity: capacity)
        cpuSystem = MetricHistory(capacity: capacity)
        memoryUsed = MetricHistory(capacity: capacity)
        networkIn = MetricHistory(capacity: capacity)
        networkOut = MetricHistory(capacity: capacity)
        diskRead = MetricHistory(capacity: capacity)
        diskWrite = MetricHistory(capacity: capacity)
        memoryUsedLong = MetricHistory(capacity: VitalsHistory.longMemoryCapacity)
        gpu = MetricHistory(capacity: capacity)
    }

    /// Fans one snapshot into every series, keeping them index-aligned by construction.
    mutating func append(_ vitals: SystemVitals) {
        cpu.append(vitals.cpuUsagePercent)
        cpuSystem.append(vitals.cpuSystemPercent)
        memoryUsed.append(Double(vitals.usedMemoryBytes))
        memoryUsedLong.append(Double(vitals.usedMemoryBytes))
        networkIn.append(vitals.networkInBytesPerSec)
        networkOut.append(vitals.networkOutBytesPerSec)
        diskRead.append(vitals.diskReadBytesPerSec)
        diskWrite.append(vitals.diskWriteBytesPerSec)
        gpu.append(vitals.gpu?.utilizationPercent ?? 0)
        appendPerCore(vitals.perCoreUsagePercent)
    }

    /// A sample without per-core data leaves the series alone rather than wiping them;
    /// a different core count makes the old series meaningless, so they start over.
    private mutating func appendPerCore(_ percentages: [Double]) {
        guard !percentages.isEmpty else { return }
        if perCore.count != percentages.count {
            perCore = percentages.map { _ in MetricHistory(capacity: capacity) }
        }
        for (index, percent) in percentages.enumerated() {
            perCore[index].append(percent)
        }
    }
}
