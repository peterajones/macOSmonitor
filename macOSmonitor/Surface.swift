//
//  Surface.swift
//  macOSmonitor
//

import Foundation

/// The top-level surfaces listed in the sidebar.
enum Surface: String, CaseIterable, Hashable, Identifiable {
    case summary, processes, cpu, gpu, memory, network, disk, thermal, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary:   return "Summary"
        case .processes: return "Processes"
        case .cpu:       return "CPU"
        case .gpu:       return "GPU"
        case .memory:    return "Memory"
        case .network:   return "Network"
        case .disk:      return "Disk"
        case .thermal:   return "Thermal"
        case .battery:   return "Battery"
        }
    }

    /// The metric this surface displays, if any. `.processes` shows a table, not a metric.
    var metric: Metric? {
        switch self {
        case .cpu:       return .cpu
        case .gpu:       return .gpu
        case .memory:    return .memory
        case .network:   return .network
        case .disk:      return .disk
        case .thermal:   return .thermal
        case .battery:   return .battery
        case .summary, .processes: return nil
        }
    }

    /// The Performance panels every Mac has, in sidebar order.
    static let performance: [Surface] = [.cpu, .memory, .network, .disk]

    /// The Performance panels for this Mac. GPU and Battery join the list only when this Mac
    /// reports them (a virtual machine may publish no GPU statistics; desktops have no
    /// battery), so no panel is permanently empty. GPU sits after CPU, as in Activity Monitor.
    static func performance(hasGPU: Bool = false, hasThermal: Bool = false, hasBattery: Bool) -> [Surface] {
        (hasGPU ? [.cpu, .gpu] : [.cpu]) + [.memory, .network, .disk]
            + (hasThermal ? [.thermal] : []) + (hasBattery ? [.battery] : [])
    }
}
