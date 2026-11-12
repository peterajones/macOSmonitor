import Foundation

/// What the menu-bar item shows, derived from the latest vitals. Pure, so the label text and
/// which rows appear are testable without a status item.
enum MenuBarReadout {
    struct Row: Equatable, Identifiable {
        let title: String
        let value: String
        /// Drives a meter; nil for rows that are a rate with no fixed maximum (Network).
        let fraction: Double?
        let metric: Metric

        var id: String { title }
    }

    /// The text beside the menu-bar icon: overall CPU, or a dash before the first sample.
    static func label(_ vitals: SystemVitals?) -> String {
        vitals?.cpuText ?? "—"
    }

    /// The panel's rows, in sidebar order. GPU and Battery appear only when this Mac reports
    /// them, matching the Performance sidebar.
    static func rows(_ vitals: SystemVitals?) -> [Row] {
        guard let vitals else { return [] }
        var rows = [Row(title: "CPU", value: vitals.cpuText,
                        fraction: vitals.cpuUsagePercent / 100, metric: .cpu)]
        if let gpu = vitals.gpu {
            rows.append(Row(title: "GPU", value: gpu.utilizationText,
                            fraction: gpu.utilizationPercent / 100, metric: .gpu))
        }
        rows.append(Row(title: "Memory", value: vitals.memoryText,
                        fraction: vitals.memoryUsedFraction, metric: .memory))
        rows.append(Row(title: "Network", value: vitals.networkText, fraction: nil, metric: .network))
        if let battery = vitals.battery {
            rows.append(Row(title: "Battery", value: battery.displayText,
                            fraction: Double(battery.chargePercent) / 100, metric: .battery))
        }
        return rows
    }
}
