import SwiftUI

/// A sidebar row: title, live value, and a thin utilisation meter in the metric's colour.
struct SidebarMeter: View {
    let title: String
    let value: String
    /// 0...1; values outside are clamped by `MeterBar`.
    let fraction: Double
    let metric: Metric

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                // The title keeps its default colour deliberately: this is a sidebar
                // list row, which must stay legible against the system sidebar
                // background under every theme, including the fixed dark palettes.
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
            }
            MeterBar(fraction: fraction,
                     orientation: .horizontal,
                     onColor: theme.color(for: metric),
                     offColor: theme.meterOff)
                .frame(height: 3)
        }
        .padding(.vertical, 2)
    }
}
