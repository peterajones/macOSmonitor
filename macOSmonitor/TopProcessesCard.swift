import SwiftUI

/// The Summary's process cell: the busiest processes by CPU, as a small table with each
/// app's icon and its memory.
///
/// Read-only by design — selecting and terminating live on the Processes surface.
struct TopProcessesCard: View {
    let model: ProcessListModel
    var limit: Int = 12

    @Environment(\.theme) private var theme

    private let pidWidth: CGFloat = 44
    private let cpuWidth: CGFloat = 40
    private let memoryWidth: CGFloat = 62
    nonisolated private static let rowHeight: CGFloat = 16
    nonisolated private static let rowSpacing: CGFloat = 3
    /// The column header, its rule, and the spacing around them.
    nonisolated private static let headerHeight: CGFloat = 14 + rowSpacing + 1 + rowSpacing

    /// How many rows fit `size` (whole rows only, up to `limit`), and whether the card is
    /// wide enough for the Memory column. Pure, so the fit is testable without a window.
    nonisolated static func layout(for size: CGSize, limit: Int) -> (rows: Int, showsMemory: Bool) {
        let rows = Int(((size.height + rowSpacing) / (rowHeight + rowSpacing)).rounded(.down))
        return (min(max(rows, 0), limit), size.width >= 280)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Processes")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            GeometryReader { geometry in
                let fit = Self.layout(for: CGSize(width: geometry.size.width,
                                                  height: geometry.size.height - Self.headerHeight),
                                      limit: limit)
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    header(showsMemory: fit.showsMemory)
                    Rectangle()
                        .fill(theme.secondaryText.opacity(0.3))
                        .frame(height: 1)
                    let rows = model.topByCPU(limit: fit.rows)
                    if rows.isEmpty {
                        Text("Sampling…")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        ForEach(rows) { row($0, showsMemory: fit.showsMemory) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(theme.secondaryText)
    }

    private func header(showsMemory: Bool) -> some View {
        HStack(spacing: 6) {
            Text("PID").frame(width: pidWidth, alignment: .trailing)
            Text("Name").padding(.leading, 20)
            Spacer(minLength: 4)
            Text("CPU").frame(width: cpuWidth, alignment: .trailing)
            if showsMemory {
                Text("Memory").frame(width: memoryWidth, alignment: .trailing)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(theme.secondaryText)
        .frame(height: 14)
    }

    private func row(_ row: ProcessInfoRow, showsMemory: Bool) -> some View {
        HStack(spacing: 6) {
            Text(String(row.pid))
                .foregroundStyle(theme.secondaryText)
                .frame(width: pidWidth, alignment: .trailing)
            icon(for: row)
            Text(row.name)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(row.cpuText)
                .foregroundStyle(theme.color(for: .cpu))
                .frame(width: cpuWidth, alignment: .trailing)
            if showsMemory {
                Text(row.memoryText)
                    .foregroundStyle(theme.primaryText)
                    .frame(width: memoryWidth, alignment: .trailing)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .frame(height: Self.rowHeight)
    }

    /// The app's own icon, or a terminal symbol for a tool outside any app bundle.
    @ViewBuilder private func icon(for row: ProcessInfoRow) -> some View {
        if let image = ProcessIconCache.shared.icon(forExecutable: row.path) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 14, height: 14)
        }
    }
}
