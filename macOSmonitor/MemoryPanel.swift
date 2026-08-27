import SwiftUI

/// The Memory Performance panel: used memory over time against total installed.
struct MemoryPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(model.vitals?.memoryText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            MetricGraph(values: model.history.memoryUsed.values,
                        range: MetricScale.fixed(Double(model.vitals?.totalMemoryBytes ?? 1)),
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

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }
}
