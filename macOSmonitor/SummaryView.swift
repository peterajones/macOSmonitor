import SwiftUI

/// The Summary dashboard: the app's landing surface.
///
/// Composes cards from data already sampled — it owns no provider of its own.
struct SummaryView: View {
    let model: ProcessListModel
    let vitalsModel: VitalsModel
    @Binding var surface: Surface?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            // The top row and the Memory card share the height; the tiles keep theirs.
            topRow
                .frame(minHeight: 200, maxHeight: .infinity)
            Button { surface = .memory } label: {
                MemoryCard(model: vitalsModel)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            statRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            meterStrip
            Button { surface = .cpu } label: {
                CPUOverviewCard(model: vitalsModel)
                    .frame(minWidth: 220)
            }
            .buttonStyle(.plain)
            Button { surface = .processes } label: {
                TopProcessesCard(model: model)
                    // Shares the width with the CPU card: 320 when there's room, down to 220,
                    // where the table drops its Memory column.
                    .frame(minWidth: 220, maxWidth: 320)
            }
            .buttonStyle(.plain)
        }
    }

    /// Only meters with a real scale: CPU and GPU are percentages, and Temp and Power use
    /// their panels' scales. Disk and Network rates have no natural maximum, so they get
    /// tiles with a labelled peak instead. Memory has its meter beside its graph.
    private var meterStrip: some View {
        let meters = SummaryMeter.all(vitals: vitalsModel.vitals, thermal: vitalsModel.thermal,
                                      power: vitalsModel.power, powerHistory: vitalsModel.powerHistory)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(meters, id: \.label) { verticalMeter($0) }
        }
        .frame(maxHeight: .infinity)
        .dashboardCard(theme.secondaryText)
    }

    private func verticalMeter(_ meter: SummaryMeter) -> some View {
        let color = theme.color(for: meter.metric)
        return VStack(spacing: 6) {
            Text(meter.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            MeterBar(fraction: meter.fraction,
                     orientation: .vertical,
                     onColor: color,
                     offColor: color.opacity(0.15),
                     glows: true)
                .frame(width: 14)
            Text(meter.value)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(color)
                .fixedSize()
        }
        .frame(minWidth: 32)
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            Button { surface = .network } label: {
                SummaryTileCard(title: "Network", systemImage: "network", metric: .network,
                                tile: .network(vitalsModel.vitals,
                                               inHistory: vitalsModel.history.networkIn,
                                               outHistory: vitalsModel.history.networkOut))
            }
            .buttonStyle(.plain)
            Button { surface = .disk } label: {
                SummaryTileCard(title: "Disk", systemImage: "internaldrive", metric: .disk,
                                tile: .disk(vitalsModel.vitals,
                                            readHistory: vitalsModel.history.diskRead,
                                            writeHistory: vitalsModel.history.diskWrite))
            }
            .buttonStyle(.plain)
            // Omitted entirely when there is no battery (M9's rule), so a desktop
            // Mac shows three tiles rather than a gap.
            if let battery = vitalsModel.vitals?.battery {
                Button { surface = .battery } label: {
                    SummaryTileCard(title: "Battery", systemImage: "battery.75percent", metric: .battery,
                                    tile: .battery(battery))
                }
                .buttonStyle(.plain)
            }
            thermalTile
        }
        .fixedSize(horizontal: false, vertical: true)   // every tile as tall as the tallest
    }

    /// Opens the Thermal panel only when it exists (it needs readable temperature sensors).
    @ViewBuilder private var thermalTile: some View {
        let card = SummaryTileCard(title: "Thermal", systemImage: "thermometer.medium", metric: .thermal,
                                   tile: .thermal(vitalsModel.vitals, cpuCelsius: vitalsModel.thermal?.cpuDieMax))
        if vitalsModel.thermal != nil {
            Button { surface = .thermal } label: { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }
}
