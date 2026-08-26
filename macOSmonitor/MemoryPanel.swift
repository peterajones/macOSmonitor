import SwiftUI

/// The Memory Performance panel: used memory over time against total installed.
struct MemoryPanel: View {
    let model: VitalsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").font(.title2)
                Spacer()
                Text(model.vitals?.memoryText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
            }

            MetricGraph(values: model.history.memoryUsed.values,
                        range: MetricScale.fixed(Double(model.vitals?.totalMemoryBytes ?? 1)),
                        lineColor: .accentColor,
                        fillColor: .accentColor.opacity(0.2),
                        gridColor: .gray.opacity(0.3))
                .frame(minHeight: 180)

            HStack {
                Text("60s ago")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
    }
}
