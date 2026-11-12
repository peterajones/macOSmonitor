import SwiftUI

/// The GPU Performance panel: utilisation over the last 60 seconds, then memory in use.
struct GPUPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("GPU").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(model.vitals?.gpuText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            MetricGraph(values: model.history.gpu.values,
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

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("GPU").foregroundStyle(theme.secondaryText)
                    Text(model.vitals?.gpu?.descriptionText ?? "—").foregroundStyle(theme.primaryText)
                }
                GridRow {
                    Text("Memory in use").foregroundStyle(theme.secondaryText)
                    Text(model.vitals?.gpu?.memoryText ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(theme.primaryText)
                }
            }
            .padding(.top, 8)

            Text("GPU memory is shared with the CPU on Apple silicon; it’s part of Memory’s total, not extra.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }
}
