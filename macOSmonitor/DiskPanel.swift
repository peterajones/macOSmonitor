import SwiftUI

/// The Disk Performance panel: read and write throughput sharing one autoscaled axis.
struct DiskPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    private var range: ClosedRange<Double> {
        MetricScale.autoscaled([model.history.diskRead, model.history.diskWrite])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(throughputText)
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            ZStack {
                MetricGraph(values: model.history.diskRead.values, range: range,
                            lineColor: theme.graphLine, fillColor: theme.graphFill,
                            gridColor: theme.gridLine)
                MetricGraph(values: model.history.diskWrite.values, range: range,
                            lineColor: theme.secondaryText, fillColor: theme.graphFill,
                            gridColor: .clear)
            }
            .frame(minHeight: 180)

            HStack {
                Text("scale: \(scaleLabel)")
                Spacer()
                Label("Read", systemImage: "arrow.down")
                Label("Write", systemImage: "arrow.up")
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private var throughputText: String {
        model.vitals?.diskText ?? "—"
    }

    private var scaleLabel: String {
        SystemVitals.rate(range.upperBound)
    }
}
