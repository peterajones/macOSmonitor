import SwiftUI

/// A full-width header bar of labeled system-vital stat items.
struct SystemVitalsView: View {
    let vitals: SystemVitals?

    var body: some View {
        HStack(spacing: 16) {
            item("CPU", vitals?.cpuText ?? "—")
            item("Memory", vitals?.memoryText ?? "—")
            item("Cores", vitals?.coresText ?? "—")
            item("Thermal", vitals?.thermalState ?? "—")
            if vitals?.lowPowerMode == true { item("Power", "Low Power") }
            item("Uptime", vitals?.uptimeText ?? "—")
            item("OS", vitals?.osVersion ?? "—")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}
