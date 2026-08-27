import SwiftUI

/// The CPU Performance panel: an overall history trace, or — via right-click —
/// a per-core grid, mirroring Task Manager's "Logical processors" toggle.
struct CPUPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme
    @State private var showsCores = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(model.vitals?.cpuText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            if showsCores {
                CoreGrid(percentages: model.vitals?.perCoreUsagePercent ?? [],
                         onColor: theme.meterOn,
                         offColor: theme.meterOff)
            } else {
                MetricGraph(values: model.history.cpu.values,
                            range: MetricScale.fixed(100),
                            lineColor: theme.graphLine,
                            fillColor: theme.graphFill,
                            gridColor: theme.gridLine)
                    .frame(minHeight: 180)
                HStack {
                    Text("60s ago")
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
            }

            HStack(spacing: 16) {
                stat("Cores", model.vitals.map { "\($0.coreCount)" })
                stat("Active", model.vitals.map { "\($0.activeCoreCount)" })
                stat("Thermal", model.vitals?.thermalState)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
        .contextMenu {
            Button(showsCores ? "Overall Utilisation" : "Logical Processors") {
                showsCores.toggle()
            }
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).textCase(.uppercase).foregroundStyle(theme.secondaryText)
            Text(value ?? "—").font(.callout).monospacedDigit().foregroundStyle(theme.primaryText)
        }
    }
}
