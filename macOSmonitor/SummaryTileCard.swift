import SwiftUI

/// One of the Summary's bottom-row tiles: icon, title and value, a detail line, and a
/// horizontal meter, in its metric's colour. The words and the meter come from `SummaryTile`.
struct SummaryTileCard: View {
    let title: String
    let systemImage: String
    let metric: Metric
    let tile: SummaryTile

    @Environment(\.theme) private var theme

    var body: some View {
        let color = theme.color(for: metric)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                Text(tile.value)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // The peak label is a nicety: when the tile is too narrow for both, the detail wins.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(tile.detail).fixedSize()
                    Spacer(minLength: 4)
                    if let scale = tile.scale { Text(scale).fixedSize() }
                }
                Text(tile.detail).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(theme.secondaryText)

            MeterBar(fraction: tile.fraction,
                     orientation: .horizontal,
                     onColor: color,
                     offColor: color.opacity(0.15),
                     glows: true)
                .frame(height: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(color)
    }
}
