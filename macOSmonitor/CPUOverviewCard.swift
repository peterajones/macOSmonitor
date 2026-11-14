import SwiftUI

/// The Summary's CPU cell: the utilisation trace plus the logical-processor count.
struct CPUOverviewCard: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU Overview")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(model.vitals?.cpuText ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(theme.color(for: .cpu))
            }

            MetricGraph(values: model.history.cpu.values,
                        range: MetricScale.fixed(100),
                        lineColor: theme.color(for: .cpu),
                        fillColor: theme.fillColor(for: .cpu),
                        gridColor: theme.gridLine,
                        timeAxis: CompressedTimeAxis(history: model.history.cpu, lastSample: model.lastSampleDate))
                .frame(minHeight: 100, maxHeight: .infinity)

            Text("\(model.vitals?.coreCount ?? 0) logical processors")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(theme.color(for: .cpu))
    }
}
