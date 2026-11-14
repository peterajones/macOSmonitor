import SwiftUI

/// The Thermal Performance panel: the hottest CPU die sensor over five minutes, then each
/// sensor group and macOS's own thermal state.
struct ThermalPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    /// Meters and the graph share a 0–100 °C scale: Apple silicon throttles in the high 90s.
    nonisolated static let scaleMax = 100.0

    /// nonisolated: pure maths, called from tests off the main actor (see SystemVitalsView).
    nonisolated static func meterFraction(_ celsius: Double?) -> Double {
        min(max((celsius ?? 0) / scaleMax, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Thermal").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(ThermalReading.text(model.thermal?.headline))
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            MetricGraph(values: model.thermalHistory.values,
                        capacity: model.thermalHistory.capacity,
                        range: MetricScale.fixed(Self.scaleMax),
                        lineColor: theme.graphLine,
                        fillColor: theme.graphFill,
                        gridColor: theme.gridLine,
                        timeAxis: CompressedTimeAxis(history: model.thermalHistory, lastSample: model.lastThermalSampleDate, sampleInterval: 2, gridInterval: 15))
                .frame(minHeight: 180)

            HStack {
                Text("Hottest CPU die sensor, last 5 min · scale 0–100 °C")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                fact("macOS thermal state", model.vitals?.thermalState ?? "—")
                fact("CPU die, hottest", ThermalReading.text(model.thermal?.cpuDieMax))
                fact("CPU die, average", ThermalReading.text(model.thermal?.cpuDieAverage))
                fact("Board, hottest", ThermalReading.text(model.thermal?.boardMax))
                fact("SSD", ThermalReading.text(model.thermal?.ssd))
                fact("Battery", ThermalReading.text(model.thermal?.battery))
            }
            .padding(.top, 8)

            Text("Read from the SMC's sensors every 2 s. Apple doesn’t document which die sensor sits over which core, so CPU readings are summarised rather than shown per core.")
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
