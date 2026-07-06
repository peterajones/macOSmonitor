import SwiftUI

/// A full-width header bar of the live system vitals, distributed as equal-width columns.
struct SystemVitalsView: View {
    let vitals: SystemVitals?

    var body: some View {
        HStack(spacing: 0) {
            item("CPU", vitals?.cpuText)
            item("Memory", vitals?.memoryText)
            item("Thermal", vitals?.thermalState)
            if vitals?.lowPowerMode == true { item("Power", "Low Power") }
            item("Uptime", vitals?.uptimeText)
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
