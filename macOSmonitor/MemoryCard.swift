import SwiftUI

/// The Summary's full-width memory band: used memory over time against total installed.
struct MemoryCard: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(model.vitals?.memoryText ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(theme.color(for: .memory))
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(spacing: 6) {
                    MeterBar(fraction: model.vitals?.memoryUsedFraction ?? 0,
                             orientation: .vertical,
                             onColor: theme.color(for: .memory),
                             offColor: theme.color(for: .memory).opacity(0.15),
                             glows: true)
                        .frame(width: 14)
                    Text(model.vitals?.memoryPercentText ?? "—")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(theme.color(for: .memory))
                        .fixedSize()
                }
                MetricGraph(values: model.history.memoryUsed.values,
                        range: MetricScale.fixed(Double(model.vitals?.totalMemoryBytes ?? 1)),
                        lineColor: theme.color(for: .memory),
                        fillColor: theme.fillColor(for: .memory),
                        gridColor: theme.gridLine,
                        timeAxis: CompressedTimeAxis(history: model.history.memoryUsed, lastSample: model.lastSampleDate))
                .frame(minHeight: 90)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(theme.color(for: .memory))
    }
}
