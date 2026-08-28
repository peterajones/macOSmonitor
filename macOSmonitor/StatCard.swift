import SwiftUI

/// One small dashboard cell: a title, a live value, and an optional utilisation meter.
///
/// Used four times in the Summary's bottom row. Thermal passes no fraction because
/// thermal pressure is a category, not a proportion.
struct StatCard: View {
    let title: String
    let value: String
    let metric: Metric
    /// 0...1 utilisation; when nil no meter is drawn.
    var fraction: Double? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }
            Text(value)
                .font(.title3)
                .monospacedDigit()
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let fraction {
                MeterBar(fraction: fraction,
                         orientation: .horizontal,
                         onColor: theme.color(for: metric),
                         offColor: theme.meterOff)
                    .frame(height: 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panelBackground)
    }
}
