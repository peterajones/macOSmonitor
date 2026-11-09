import SwiftUI

/// The Memory Performance panel: overall use, recent history, and the breakdown behind it.
struct MemoryPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    private let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory").font(.title2).foregroundStyle(theme.primaryText)

            HStack(spacing: 12) {
                MeterBar(fraction: model.vitals?.memoryUsedFraction ?? 0,
                         orientation: .horizontal,
                         onColor: theme.color(for: .memory),
                         offColor: theme.meterOff)
                    .frame(height: 14)
                Text(model.vitals?.memoryPercentText ?? "—")
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(theme.color(for: .memory))
            }

            Text(model.vitals?.memoryText ?? "—")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)

            MetricGraph(values: model.history.memoryUsed.values,
                        range: graphRange,
                        lineColor: theme.color(for: .memory),
                        fillColor: theme.fillColor(for: .memory),
                        gridColor: theme.gridLine)
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) { rangeLabel(graphRange.upperBound) }
                .overlay(alignment: .bottomLeading) { rangeLabel(graphRange.lowerBound) }
                .overlay { Rectangle().strokeBorder(theme.color(for: .memory), lineWidth: 1) }

            HStack {
                Text("60s ago")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                readout("In use", model.vitals?.usedMemoryText)
                readout("Available", model.vitals?.availableMemoryText)
                readout("Cached", model.vitals?.cachedMemoryText)
                readout("Pressure", model.vitals?.memoryPressureText)
                readout("App memory", model.vitals?.appMemoryText)
                readout("Wired", model.vitals?.wiredMemoryText)
                readout("Compressed", model.vitals?.compressedMemoryText)
                readout("Swap", model.vitals?.swapText)
                readout("Page ins", model.vitals?.pageInsText)
                readout("Page outs", model.vitals?.pageOutsText)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    /// Zoomed to the last minute so ordinary movement is visible; a 1 GB minimum span
    /// keeps an idle machine's trace flat.
    private var graphRange: ClosedRange<Double> {
        MetricScale.zoomed(model.history.memoryUsed.values,
                           ceiling: Double(model.vitals?.totalMemoryBytes ?? 1),
                           minimumSpan: 1_073_741_824)
    }

    private func rangeLabel(_ bytes: Double) -> some View {
        Text(SystemVitals.gigabytes(bytes))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(theme.color(for: .memory))
            .padding(6)
    }

    private func readout(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text(value ?? "—")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
