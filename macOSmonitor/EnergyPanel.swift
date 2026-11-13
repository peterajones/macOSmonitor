import SwiftUI

/// The Energy Performance panel: whole-system power over the last 60 seconds, then where it
/// comes from (adapter, battery) and the GPU's share.
struct EnergyPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    /// The graph's and meter's scale: at least 10 W so an idle Mac doesn't fill the graph,
    /// otherwise the last minute's peak. nonisolated: called from tests off the main actor.
    nonisolated static func range(_ history: MetricHistory) -> ClosedRange<Double> {
        MetricScale.autoscaled([history], floor: 10)
    }

    nonisolated static func meterFraction(_ watts: Double?, history: MetricHistory) -> Double {
        min(max((watts ?? 0) / range(history).upperBound, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Energy").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(PowerReading.text(model.power?.systemWatts))
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            MetricGraph(values: model.powerHistory.values,
                        capacity: model.powerHistory.capacity,
                        range: Self.range(model.powerHistory),
                        lineColor: theme.graphLine,
                        fillColor: theme.graphFill,
                        gridColor: theme.gridLine)
                .frame(minHeight: 180)

            HStack {
                Text("System power, last 60 s · scale 0–\(Int(Self.range(model.powerHistory).upperBound.rounded(.up))) W")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                fact("System total", PowerReading.text(model.power?.systemWatts))
                fact("From power adapter", PowerReading.text(model.power?.adapterWatts))
                fact("Battery, in or out", PowerReading.text(model.power?.batteryWatts))
                fact("GPU", PowerReading.text(model.power?.gpuWatts))
            }
            .padding(.top, 8)

            Text("System, adapter and battery power come from the SMC; GPU power from its energy counter. macOS 27 no longer updates the CPU, Neural Engine and memory energy counters, so they aren’t shown.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.secondaryText)
            Text(value).monospacedDigit().foregroundStyle(theme.primaryText)
        }
    }
}
