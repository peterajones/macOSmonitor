import SwiftUI

/// The Network Performance panel: received and sent, sharing one autoscaled axis.
struct NetworkPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    private var range: ClosedRange<Double> {
        MetricScale.autoscaled([model.history.networkIn, model.history.networkOut])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Network").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(model.vitals?.networkText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            ZStack {
                MetricGraph(values: model.history.networkIn.values,
                            range: range,
                            lineColor: theme.graphLine,
                            fillColor: theme.graphFill,
                            gridColor: theme.gridLine)
                MetricGraph(values: model.history.networkOut.values,
                            range: range,
                            lineColor: theme.secondaryText,
                            fillColor: theme.graphFill,
                            gridColor: .clear)
            }
            .frame(minHeight: 180)

            HStack {
                Text("scale: \(scaleLabel)")
                Spacer()
                Label("Received", systemImage: "arrow.down").foregroundStyle(theme.graphLine)
                Label("Sent", systemImage: "arrow.up").foregroundStyle(theme.secondaryText)
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            if let interfaces = model.vitals?.networkInterfaces, !interfaces.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text("Interface")
                        Label("Received", systemImage: "arrow.down")
                            .gridColumnAlignment(.trailing)
                        Label("Sent", systemImage: "arrow.up")
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(interfaces, id: \.name) { row in
                        GridRow {
                            Text(row.name).foregroundStyle(theme.primaryText)
                            Text(row.inText).foregroundStyle(theme.graphLine)
                            Text(row.outText).foregroundStyle(theme.secondaryText)
                        }
                        .monospacedDigit()
                    }
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private var scaleLabel: String {
        SystemVitals.rate(range.upperBound)
    }
}
