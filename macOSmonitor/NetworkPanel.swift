import SwiftUI

/// The Network Performance panel: received and sent, sharing one autoscaled axis.
struct NetworkPanel: View {
    let model: VitalsModel

    private var range: ClosedRange<Double> {
        MetricScale.autoscaled([model.history.networkIn, model.history.networkOut])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Network").font(.title2)
                Spacer()
                Text(model.vitals?.networkText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
            }

            ZStack {
                MetricGraph(values: model.history.networkIn.values,
                            range: range,
                            lineColor: .accentColor,
                            fillColor: .accentColor.opacity(0.2),
                            gridColor: .gray.opacity(0.3))
                MetricGraph(values: model.history.networkOut.values,
                            range: range,
                            lineColor: .orange,
                            fillColor: .orange.opacity(0.15),
                            gridColor: .clear)
            }
            .frame(minHeight: 180)

            HStack {
                Text("scale: \(scaleLabel)")
                Spacer()
                Label("Received", systemImage: "arrow.down").foregroundStyle(Color.accentColor)
                Label("Sent", systemImage: "arrow.up").foregroundStyle(.orange)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
    }

    private var scaleLabel: String {
        let bytes = range.upperBound
        if bytes < 1_000_000 { return String(format: "%.0f KB/s", bytes / 1_000) }
        return String(format: "%.1f MB/s", bytes / 1_000_000)
    }
}
