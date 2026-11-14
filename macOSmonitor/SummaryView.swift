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
            topRow
            Button { surface = .memory } label: {
                MemoryCard(model: vitalsModel)
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
            }
            .buttonStyle(.plain)
            Button { surface = .processes } label: {
                TopProcessesCard(model: model)
                    .frame(width: 280)
            }
            .buttonStyle(.plain)
        }
    }

    /// CPU and Memory only: they are the two metrics with a genuine 0-100% ceiling.
    /// Disk and Network rates have no natural maximum, so a "percent full" meter for
    /// them would be a fraction of a recent autoscaled peak — it would look like a
    /// utilisation reading without being one.
    private var meterStrip: some View {
        HStack(alignment: .bottom, spacing: 10) {
            verticalMeter(title: "CPU", metric: .cpu, fraction: cpuFraction)
            verticalMeter(title: "MEM", metric: .memory, fraction: memoryFraction)
        }
        .frame(width: 76)
        .frame(maxHeight: .infinity)
        .dashboardCard(theme.secondaryText)
    }

    private func verticalMeter(title: String, metric: Metric, fraction: Double) -> some View {
        VStack(spacing: 6) {
            MeterBar(fraction: fraction,
                     orientation: .vertical,
                     onColor: theme.color(for: metric),
                     offColor: theme.meterOff)
                .frame(width: 14)
            Text(title)
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var cpuFraction: Double {
        (vitalsModel.vitals?.cpuUsagePercent ?? 0) / 100
    }

    private var memoryFraction: Double {
        guard let vitals = vitalsModel.vitals, vitals.totalMemoryBytes > 0 else { return 0 }
        return Double(vitals.usedMemoryBytes) / Double(vitals.totalMemoryBytes)
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
