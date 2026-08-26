import SwiftUI

/// The CPU Performance panel: an overall history trace, or — via right-click —
/// a per-core grid, mirroring Task Manager's "Logical processors" toggle.
struct CPUPanel: View {
    let model: VitalsModel
    @State private var showsCores = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(.title2)
                Spacer()
                Text(model.vitals?.cpuText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
            }

            if showsCores {
                CoreGrid(percentages: model.vitals?.perCoreUsagePercent ?? [],
                         onColor: .accentColor,
                         offColor: .gray.opacity(0.15))
            } else {
                MetricGraph(values: model.history.cpu.values,
                            range: MetricScale.fixed(100),
                            lineColor: .accentColor,
                            fillColor: .accentColor.opacity(0.2),
                            gridColor: .gray.opacity(0.3))
                    .frame(minHeight: 180)
                HStack {
                    Text("60s ago")
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                stat("Cores", model.vitals.map { "\($0.coreCount)" })
                stat("Active", model.vitals.map { "\($0.activeCoreCount)" })
                stat("Thermal", model.vitals?.thermalState)
            }
            Spacer()
        }
        .padding(20)
        .contextMenu {
            Button(showsCores ? "Overall Utilisation" : "Logical Processors") {
                showsCores.toggle()
            }
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).textCase(.uppercase).foregroundStyle(.secondary)
            Text(value ?? "—").font(.callout).monospacedDigit()
        }
    }
}
