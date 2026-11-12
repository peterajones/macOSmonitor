//
//  Surface.swift
//  macOSmonitor
//

import Foundation

/// The top-level surfaces listed in the sidebar.
enum Surface: String, CaseIterable, Hashable, Identifiable {
    case summary, processes, cpu, memory, network, disk, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary:   return "Summary"
        case .processes: return "Processes"
        case .cpu:       return "CPU"
        case .memory:    return "Memory"
        case .network:   return "Network"
        case .disk:      return "Disk"
        case .battery:   return "Battery"
        }
    }

    /// The metric this surface displays, if any. `.processes` shows a table, not a metric.
    var metric: Metric? {
        switch self {
        case .cpu:       return .cpu
        case .memory:    return .memory
        case .network:   return .network
        case .disk:      return .disk
        case .battery:   return .battery
        case .summary, .processes: return nil
        }
    }

    /// The Performance panels every Mac has, in sidebar order.
    static let performance: [Surface] = [.cpu, .memory, .network, .disk]

    /// The Performance panels for this Mac: Battery joins the list only when one is present,
    /// so desktops don't show an empty panel.
    static func performance(hasBattery: Bool) -> [Surface] {
        hasBattery ? performance + [.battery] : performance
    }
}
