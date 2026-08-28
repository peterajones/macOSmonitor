//
//  Surface.swift
//  macOSmonitor
//

import Foundation

/// The top-level surfaces listed in the sidebar.
enum Surface: String, CaseIterable, Hashable, Identifiable {
    case processes, cpu, memory, network, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processes: return "Processes"
        case .cpu:       return "CPU"
        case .memory:    return "Memory"
        case .network:   return "Network"
        case .disk:      return "Disk"
        }
    }

    /// The metric this surface displays, if any. `.processes` shows a table, not a metric.
    var metric: Metric? {
        switch self {
        case .cpu:       return .cpu
        case .memory:    return .memory
        case .network:   return .network
        case .disk:      return .disk
        case .processes: return nil
        }
    }

    /// The four Performance panels, in sidebar order.
    static let performance: [Surface] = [.cpu, .memory, .network, .disk]
}
