import SwiftUI

/// One labelled figure in the Energy panel.
struct EnergyFact: Equatable, Identifiable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

/// The Energy Performance panel: whole-system power over the last 60 seconds, where it
/// comes from (adapter, battery), the GPU's share, and the processes drawing the most.
struct EnergyPanel: View {
    let model: VitalsModel
    /// The window's process list, for the top processes by power.
    let processes: ProcessListModel
    @Environment(\.theme) private var theme

    /// The graph's and meter's scale: at least 10 W so an idle Mac doesn't fill the graph,
    /// otherwise the last minute's peak. nonisolated: called from tests off the main actor.
    nonisolated static func range(_ history: MetricHistory) -> ClosedRange<Double> {
        MetricScale.autoscaled([history], floor: 10)
    }

    /// The panel's figures: System total always, the rest only where this Mac reports them
    /// (no Battery row on a desktop, no GPU row without the counter). Adapter power on battery
    /// is a real 0, so it stays.
    nonisolated static func facts(_ power: PowerReading?) -> [EnergyFact] {
        var facts = [EnergyFact(label: "System total", value: PowerReading.text(power?.systemWatts))]
        let optional: [(String, Double?)] = [("From power adapter", power?.adapterWatts),
                                              ("Battery, in or out", power?.batteryWatts),
                                              ("GPU", power?.gpuWatts)]
        for (label, watts) in optional where watts != nil {
            facts.append(EnergyFact(label: label, value: PowerReading.text(watts)))
        }
        return facts
    }

    nonisolated static func meterFraction(_ watts: Double?, history: MetricHistory) -> Double {
        min(max((watts ?? 0) / range(history).upperBound, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Energy").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(PowerReading.text(model.power?.systemWatts))
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            MetricGraph(values: model.powerHistory.values,
                        capacity: model.powerHistory.capacity,
                        range: Self.range(model.powerHistory),
                        lineColor: theme.graphLine,
                        fillColor: theme.graphFill,
                        gridColor: theme.gridLine,
                        timeAxis: CompressedTimeAxis(history: model.powerHistory, lastSample: model.lastSampleDate))
                .frame(minHeight: 180)

            HStack {
                Text("System power, last 60 s · scale 0–\(Int(Self.range(model.powerHistory).upperBound.rounded(.up))) W")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(Self.facts(model.power)) { fact in
                    self.fact(fact.label, fact.value)
                }
            }
            .padding(.top, 8)

            Text("Top processes by power")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
                .padding(.top, 8)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(ProcessInfoRow.topByPower(processes.rows, limit: 8)) { row in
                    GridRow {
                        Text(row.name).lineLimit(1).foregroundStyle(theme.primaryText)
                        Text(PowerReading.text(row.powerWatts))
                            .monospacedDigit()
                            .foregroundStyle(theme.primaryText)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }

            Text("System, adapter and battery power come from the SMC; GPU power from its energy counter. macOS 27 no longer updates the CPU, Neural Engine and memory energy counters, so they aren’t shown. Per-process power is the kernel’s estimate for each process; processes that aren’t yours need the privileged helper.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.secondaryText)
            Text(value).monospacedDigit().foregroundStyle(theme.primaryText)
        }
    }
}
