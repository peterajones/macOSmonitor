import SwiftUI

/// The Summary's process cell: the busiest processes by CPU.
///
/// Read-only by design — selecting and terminating live on the Processes surface.
struct TopProcessesCard: View {
    let model: ProcessListModel
    var limit: Int = 8

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Processes")
                .font(.headline)
                .foregroundStyle(theme.primaryText)

            let rows = model.topByCPU(limit: limit)
            if rows.isEmpty {
                Text("Sampling…")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text(String(row.pid))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 50, alignment: .trailing)
                        Text(row.name)
                            .font(.caption)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(row.cpuText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(theme.color(for: .cpu))
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panelBackground)
    }
}
