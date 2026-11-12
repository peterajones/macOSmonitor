import SwiftUI

/// One small 60-second trace per logical core, drawn with the same `MetricGraph` as the
/// overall CPU graph. The newest sample is at each trace's right edge.
struct CoreGrid: View {
    let histories: [MetricHistory]
    /// "P1", "E3", … or "0", "1", … when the core layout is unknown.
    let labels: [String]
    let lineColor: Color
    let fillColor: Color
    let backgroundColor: Color
    @Environment(\.theme) private var theme

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(histories.enumerated()), id: \.offset) { index, history in
                VStack(spacing: 4) {
                    // No grid lines: at this size they'd be clutter, not a scale.
                    MetricGraph(values: history.values,
                                capacity: history.capacity,
                                range: MetricScale.fixed(100),
                                lineColor: lineColor,
                                fillColor: fillColor,
                                gridColor: .clear)
                        .background(backgroundColor)
                        .frame(height: 56)
                    Text(index < labels.count ? labels[index] : "\(index)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }
}
