import Testing
import Foundation
@testable import macOSmonitor

/// The Summary's CPU graph overlays kernel CPU and CPU temperature on utilisation.
struct KernelCPUTests {
    @Test func kernelShareIsTheSumOfSystemDeltasNotTheAverageOfPercents() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 0, total: 0, system: 0), CoreTicks(busy: 0, total: 0, system: 0)]
        let sampler = SystemVitalsSampler(host: fake)
        let first = await sampler.sample()
        #expect(first.cpuSystemPercent == 0)              // no baseline yet

        // core 0: 10 system of 100; core 1: 50 system of 300 → 60 of 400 = 15%.
        // Averaging the per-core shares (10% and 16.7%) would give 13.3%.
        fake.ticks = [CoreTicks(busy: 30, total: 100, system: 10), CoreTicks(busy: 70, total: 300, system: 50)]
        let sample = await sampler.sample()
        #expect(sample.cpuSystemPercent == 15)
        #expect(sample.cpuUsagePercent == 25)             // the total is unchanged by the split
    }

    @Test func aSystemCounterGoingBackwardsCountsAsNoKernelTime() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 0, total: 0, system: 500)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()

        fake.ticks = [CoreTicks(busy: 40, total: 100, system: 20)]   // wrapped: must not trap
        let sample = await sampler.sample()
        #expect(sample.cpuSystemPercent == 0)
        #expect(sample.cpuUsagePercent == 40)
    }

    @Test func historyRecordsKernelShareEachTick() {
        var history = VitalsHistory()
        var vitals = SystemVitals(cpuUsagePercent: 40, usedMemoryBytes: 0, totalMemoryBytes: 1, coreCount: 1,
                                  activeCoreCount: 1, thermalState: "Nominal", lowPowerMode: false,
                                  uptime: 0, osVersion: "macOS 27.2")
        vitals.cpuSystemPercent = 15
        history.append(vitals)
        #expect(history.cpuSystem.values == [15])
        #expect(history.cpu.values == [40])
    }
}

@MainActor
struct CPUTemperatureHistoryTests {
    /// Temperatures are read every 2 s, but the CPU graph has a sample a second; the latest
    /// reading is recorded on every vitals tick so the two lines line up second for second.
    @Test func eachVitalsTickRecordsTheLatestTemperature() async {
        let thermal = FakeThermalSampler()
        let model = VitalsModel(sampler: FakeVitalsSampler(), thermalSampler: thermal)

        await model.refreshOnce()                         // no reading yet: nothing recorded
        #expect(model.cpuTemperatureHistory.values.isEmpty)

        thermal.next = ThermalReading(cpuDieMax: 47, cpuDieAverage: 44, boardMax: nil, ssd: nil, battery: nil)
        await model.refreshThermalOnce()
        await model.refreshOnce()
        await model.refreshOnce()                         // no new reading: repeat the latest
        #expect(model.cpuTemperatureHistory.values == [47, 47])
        #expect(model.cpuTemperatureHistory.capacity == model.history.cpu.capacity)
    }

    @Test func noTemperatureIsRecordedOnceSensorsGoAway() async {
        let thermal = FakeThermalSampler()
        let model = VitalsModel(sampler: FakeVitalsSampler(), thermalSampler: thermal)
        thermal.next = ThermalReading(cpuDieMax: 47, cpuDieAverage: 44, boardMax: nil, ssd: nil, battery: nil)
        await model.refreshThermalOnce()
        await model.refreshOnce()
        thermal.next = nil
        await model.refreshThermalOnce()
        await model.refreshOnce()
        #expect(model.cpuTemperatureHistory.values == [47])
    }
}

struct CPUOverviewTextTests {
    @Test func footerAddsPowerWhenThisMacReportsIt() {
        #expect(CPUOverviewCard.footer(coreCount: 12, cpuText: "20%", watts: 22.24)
                == "12 logical processors · 20% · 22.2 W")
        #expect(CPUOverviewCard.footer(coreCount: 12, cpuText: "20%", watts: nil)
                == "12 logical processors · 20%")
    }
}
