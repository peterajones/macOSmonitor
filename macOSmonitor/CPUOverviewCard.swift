import SwiftUI

/// The Summary's CPU cell: utilisation with the kernel's share and the CPU temperature
/// overlaid, % on the left axis and °C on the right, and a one-line footer.
struct CPUOverviewCard: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    /// "12 logical processors · 20% · 22.2 W"; the power figure only where this Mac reports it.
    nonisolated static func footer(coreCount: Int, cpuText: String, watts: Double?) -> String {
        var parts = ["\(coreCount) logical processors", cpuText]
        if let watts { parts.append(PowerReading.text(watts)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let cpuColor = theme.color(for: .cpu)
        let kernelColor = theme.secondaryText
        let temperatureColor = theme.color(for: .thermal)
        // No sensors (or none read yet): no temperature line, legend entry or °C axis.
        let showsTemperature = !model.cpuTemperatureHistory.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU Overview")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(model.vitals?.cpuText ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(cpuColor)
            }

            HStack(spacing: 12) {
                legend("Utilization", cpuColor)
                legend("Kernel", kernelColor)
                if showsTemperature { legend("Temperature", temperatureColor) }
            }

            HStack(spacing: 4) {
                axis(["100%", "50%", "0%"], color: cpuColor)
                ZStack {
                    MetricGraph(values: model.history.cpu.values,
                                range: MetricScale.fixed(100),
                                lineColor: cpuColor,
                                fillColor: theme.fillColor(for: .cpu),
                                gridColor: theme.gridLine,
                                timeAxis: CompressedTimeAxis(history: model.history.cpu,
                                                             lastSample: model.lastSampleDate))
                    MetricGraph(values: model.history.cpuSystem.values,
                                range: MetricScale.fixed(100),
                                lineColor: kernelColor,
                                fillColor: .clear,
                                gridColor: .clear,
                                timeAxis: CompressedTimeAxis(history: model.history.cpuSystem,
                                                             lastSample: model.lastSampleDate),
                                showsBorder: false)
                    if showsTemperature {
                        MetricGraph(values: model.cpuTemperatureHistory.values,
                                    range: MetricScale.fixed(ThermalPanel.scaleMax),
                                    lineColor: temperatureColor,
                                    fillColor: .clear,
                                    gridColor: .clear,
                                    timeAxis: CompressedTimeAxis(history: model.cpuTemperatureHistory,
                                                                 lastSample: model.lastSampleDate),
                                    showsBorder: false)
                    }
                }
                if showsTemperature {
                    axis(["\(Int(ThermalPanel.scaleMax))°", "\(Int(ThermalPanel.scaleMax / 2))°", "0°"],
                         color: temperatureColor)
                }
            }
            .frame(minHeight: 80, maxHeight: .infinity)

            Text(Self.footer(coreCount: model.vitals?.coreCount ?? 0,
                             cpuText: model.vitals?.cpuText ?? "—",
                             watts: model.power?.systemWatts))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(cpuColor)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .lineLimit(1)
    }

    /// Top, middle and bottom labels, level with the graph's top, centre line and bottom.
    private func axis(_ labels: [String], color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(labels[0])
            Spacer(minLength: 0)
            Text(labels[1])
            Spacer(minLength: 0)
            Text(labels[2])
        }
        .font(.system(size: 9))
        .monospacedDigit()
        .foregroundStyle(color)
        .fixedSize(horizontal: true, vertical: false)
    }
}
