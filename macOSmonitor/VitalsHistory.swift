import Foundation

/// Six index-aligned sliding windows of system vitals, fed one `SystemVitals`
/// snapshot at a time. No clock, no syscalls, no SwiftUI.
struct VitalsHistory: Equatable, Sendable {
    var cpu: MetricHistory
    var memoryUsed: MetricHistory
    var networkIn: MetricHistory
    var networkOut: MetricHistory
    var diskRead: MetricHistory
    var diskWrite: MetricHistory

    init(capacity: Int = 60) {
        cpu = MetricHistory(capacity: capacity)
        memoryUsed = MetricHistory(capacity: capacity)
        networkIn = MetricHistory(capacity: capacity)
        networkOut = MetricHistory(capacity: capacity)
        diskRead = MetricHistory(capacity: capacity)
        diskWrite = MetricHistory(capacity: capacity)
    }

    /// Fans one snapshot into all six series, keeping them index-aligned by construction.
    mutating func append(_ vitals: SystemVitals) {
        cpu.append(vitals.cpuUsagePercent)
        memoryUsed.append(Double(vitals.usedMemoryBytes))
        networkIn.append(vitals.networkInBytesPerSec)
        networkOut.append(vitals.networkOutBytesPerSec)
        diskRead.append(vitals.diskReadBytesPerSec)
        diskWrite.append(vitals.diskWriteBytesPerSec)
    }
}
