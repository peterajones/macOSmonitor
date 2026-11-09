import Foundation

/// Six index-aligned sliding windows of system vitals, plus a longer memory window for
/// the Memory panel's compressed graph, fed one `SystemVitals` snapshot at a time.
/// No clock, no syscalls, no SwiftUI.
struct VitalsHistory: Equatable, Sendable {
    var cpu: MetricHistory
    var memoryUsed: MetricHistory
    var networkIn: MetricHistory
    var networkOut: MetricHistory
    var diskRead: MetricHistory
    var diskWrite: MetricHistory
    var memoryUsedLong: MetricHistory

    static let longMemoryCapacity = 300

    init(capacity: Int = 60) {
        cpu = MetricHistory(capacity: capacity)
        memoryUsed = MetricHistory(capacity: capacity)
        networkIn = MetricHistory(capacity: capacity)
        networkOut = MetricHistory(capacity: capacity)
        diskRead = MetricHistory(capacity: capacity)
        diskWrite = MetricHistory(capacity: capacity)
        memoryUsedLong = MetricHistory(capacity: VitalsHistory.longMemoryCapacity)
    }

    /// Fans one snapshot into every series, keeping them index-aligned by construction.
    mutating func append(_ vitals: SystemVitals) {
        cpu.append(vitals.cpuUsagePercent)
        memoryUsed.append(Double(vitals.usedMemoryBytes))
        memoryUsedLong.append(Double(vitals.usedMemoryBytes))
        networkIn.append(vitals.networkInBytesPerSec)
        networkOut.append(vitals.networkOutBytesPerSec)
        diskRead.append(vitals.diskReadBytesPerSec)
        diskWrite.append(vitals.diskWriteBytesPerSec)
    }
}
