import Testing
@testable import macOSmonitor

/// The Summary's meter column: CPU always, and GPU, Temp and Power only where this Mac
/// reports them, each with its label, fill and value.
struct SummaryMeterTests {
    private func vitals(cpu: Double = 25, gpu: Double? = nil) -> SystemVitals {
        SystemVitals(cpuUsagePercent: cpu, usedMemoryBytes: 0, totalMemoryBytes: 1, coreCount: 1,
                     activeCoreCount: 1, thermalState: "Nominal", lowPowerMode: false,
                     uptime: 0, osVersion: "macOS 27.2",
                     gpu: gpu.map { GPUInfo(utilizationPercent: $0, memoryInUseBytes: nil) })
    }

    private func power(_ watts: Double?) -> PowerReading {
        PowerReading(systemWatts: watts, adapterWatts: nil, batteryWatts: nil, gpuWatts: nil)
    }

    private func powerHistory(_ values: [Double]) -> MetricHistory {
        var history = MetricHistory(capacity: 60)
        values.forEach { history.append($0) }
        return history
    }

    private func thermal(_ cpu: Double?) -> ThermalReading {
        ThermalReading(cpuDieMax: cpu, cpuDieAverage: nil, boardMax: 30, ssd: nil, battery: nil)
    }

    @Test func onlyCPUWhenNothingElseIsReadable() {
        let meters = SummaryMeter.all(vitals: vitals(), thermal: nil, power: nil, powerHistory: powerHistory([]))
        #expect(meters.map(\.label) == ["CPU"])
    }

    @Test func everyMeterInOrderWhenAllAreReadable() {
        let meters = SummaryMeter.all(vitals: vitals(gpu: 10), thermal: thermal(50),
                                      power: power(20), powerHistory: powerHistory([20]))
        #expect(meters.map(\.label) == ["CPU", "GPU", "Temp", "Power"])
        #expect(meters.map(\.metric) == [.cpu, .gpu, .thermal, .energy])
    }

    @Test func cpuAndGPUAreTheirPercentages() {
        let meters = SummaryMeter.all(vitals: vitals(cpu: 25, gpu: 40), thermal: nil, power: nil,
                                      powerHistory: powerHistory([]))
        #expect(meters.map(\.fraction) == [0.25, 0.4])
        #expect(meters.map(\.value) == ["25%", "40%"])
    }

    @Test func tempUsesTheThermalPanelsScaleAndHeadline() {
        let meter = SummaryMeter.all(vitals: vitals(), thermal: thermal(55), power: nil,
                                     powerHistory: powerHistory([]))[1]
        #expect(meter.fraction == ThermalPanel.meterFraction(55))
        #expect(meter.value == "55 °C")
        // Without a CPU die sensor, the headline falls back to the hottest other sensor.
        let fallback = SummaryMeter.all(vitals: vitals(), thermal: thermal(nil), power: nil,
                                        powerHistory: powerHistory([]))[1]
        #expect(fallback.value == "30 °C")
    }

    @Test func powerUsesTheEnergyPanelsScale() {
        let history = powerHistory([10, 40, 20])
        let meter = SummaryMeter.all(vitals: vitals(), thermal: nil, power: power(20), powerHistory: history)[1]
        #expect(meter.label == "Power")
        #expect(meter.fraction == EnergyPanel.meterFraction(20, history: history))
        #expect(meter.value == "20.0 W")
    }

    @Test func aPowerReadingWithoutASystemFigureHasNoMeter() {
        let meters = SummaryMeter.all(vitals: vitals(), thermal: nil, power: power(nil),
                                      powerHistory: powerHistory([]))
        #expect(meters.map(\.label) == ["CPU"])
    }

    @Test func noVitalsYetStillShowsAnEmptyCPUMeter() {
        let meters = SummaryMeter.all(vitals: nil, thermal: nil, power: nil, powerHistory: powerHistory([]))
        #expect(meters.map(\.label) == ["CPU"])
        #expect(meters[0].fraction == 0)
        #expect(meters[0].value == "—")
    }
}
