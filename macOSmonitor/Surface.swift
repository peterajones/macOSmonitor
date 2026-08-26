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

    /// The four Performance panels, in sidebar order.
    static let performance: [Surface] = [.cpu, .memory, .network, .disk]
}
