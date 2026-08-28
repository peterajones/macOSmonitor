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
            // Both the title and the value keep their default semantic colours
            // deliberately. This row sits on the SYSTEM sidebar background, not on
            // theme.panelBackground, so a fixed dark palette's text colour renders
            // dark-on-light here and is barely legible. Only the meter is themed —
            // it is the element that actually sits on its own track.
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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
