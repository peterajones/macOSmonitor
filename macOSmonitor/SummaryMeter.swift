import Foundation

/// One meter in the Summary's column: CPU always; GPU, Temp and Power only where this Mac
/// reports them. Temp and Power borrow their panels' scales, so a meter here reads the same
/// as the one on its panel.
struct SummaryMeter: Equatable, Sendable {
    let label: String
    let metric: Metric
    /// 0...1.
    let fraction: Double
    let value: String

    nonisolated static func all(vitals: SystemVitals?, thermal: ThermalReading?, power: PowerReading?,
                                powerHistory: MetricHistory) -> [SummaryMeter] {
        var meters = [SummaryMeter(label: "CPU", metric: .cpu,
                                   fraction: (vitals?.cpuUsagePercent ?? 0) / 100,
                                   value: vitals?.cpuText ?? "—")]
        if let gpu = vitals?.gpu {
            meters.append(SummaryMeter(label: "GPU", metric: .gpu, fraction: gpu.utilizationPercent / 100,
                                       value: gpu.utilizationText))
        }
        if let celsius = thermal?.headline {
            meters.append(SummaryMeter(label: "Temp", metric: .thermal,
                                       fraction: ThermalPanel.meterFraction(celsius),
                                       value: ThermalReading.text(celsius)))
        }
        if let watts = power?.systemWatts {
            meters.append(SummaryMeter(label: "Power", metric: .energy,
                                       fraction: EnergyPanel.meterFraction(watts, history: powerHistory),
                                       value: PowerReading.text(watts)))
        }
        return meters
    }
}
