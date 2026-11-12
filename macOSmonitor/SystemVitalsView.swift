import SwiftUI

/// A full-width header bar of the live system vitals, distributed as equal-width columns.
struct SystemVitalsView: View {
    let vitals: SystemVitals?
    var thermal: ThermalReading? = nil

    /// "Nominal · 44 °C", or just the state when temperatures are unavailable.
    /// nonisolated: pure formatting. A static on a View is otherwise main-actor-only in
    /// Swift 6, and calling it off the main actor traps at run time (it crashed the test host).
    nonisolated static func thermalText(state: String?, celsius: Double?) -> String? {
        guard let celsius else { return state }
        return [state, ThermalReading.text(celsius)].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 0) {
            item("CPU", vitals?.cpuText)
            if let gpu = vitals?.gpu { item("GPU", gpu.utilizationText) }
            item("Memory", vitals?.memoryText)
            item("Network", vitals?.networkText)
            item("Thermal", Self.thermalText(state: vitals?.thermalState, celsius: thermal?.headline))
            if vitals?.lowPowerMode == true { item("Power", "Low Power") }
            item("Uptime", vitals?.uptimeText)
            if let battery = vitals?.battery { item("Battery", battery.displayText) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func item(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.callout)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // equal columns, spread to full width
    }
}
