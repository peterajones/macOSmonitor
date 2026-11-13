import Testing
import Foundation
@testable import macOSmonitor

final class FakeSMCPower: SMCPowerProviding, @unchecked Sendable {
    var next: SMCPower?
    func read() -> SMCPower? { next }
}

final class FakeGPUEnergy: GPUEnergyProviding, @unchecked Sendable {
    var nanojoules: UInt64?
    func totalNanojoules() -> UInt64? { nanojoules }
}

final class FakePowerSampler: PowerSampling, @unchecked Sendable {
    var next: PowerReading?
    func sample() async -> PowerReading? { next }
}

struct PowerSamplerTests {
    final class Clock: @unchecked Sendable { var nanos: UInt64 = 0 }

    private func make() -> (PowerSampler, FakeSMCPower, FakeGPUEnergy, Clock) {
        let smc = FakeSMCPower(), gpu = FakeGPUEnergy(), clock = Clock()
        return (PowerSampler(smc: smc, gpu: gpu, now: { clock.nanos }), smc, gpu, clock)
    }

    @Test func gpuWattsComeFromTheEnergyCounterAfterTheFirstTick() async {
        let (sampler, smc, gpu, clock) = make()
        smc.next = SMCPower(systemWatts: 15, adapterWatts: 18, batteryWatts: 0.7)
        gpu.nanojoules = 1_000_000_000
        clock.nanos = 1_000_000_000
        let first = await sampler.sample()
        #expect(first?.systemWatts == 15)
        #expect(first?.gpuWatts == nil)                          // no baseline yet

        gpu.nanojoules = 4_000_000_000                           // +3 J over 2 s
        clock.nanos = 3_000_000_000
        #expect(await sampler.sample()?.gpuWatts == 1.5)
    }

    @Test func aCounterThatGoesBackwardsGivesNoGPUReading() async {
        let (sampler, smc, gpu, clock) = make()
        smc.next = SMCPower(systemWatts: 15, adapterWatts: nil, batteryWatts: nil)
        gpu.nanojoules = 9_000_000_000
        clock.nanos = 1_000_000_000
        _ = await sampler.sample()
        gpu.nanojoules = 1_000                                   // reset (sleep/wake, driver restart)
        clock.nanos = 2_000_000_000
        let reading = await sampler.sample()
        #expect(reading?.gpuWatts == nil)
        #expect(reading?.systemWatts == 15)
    }

    @Test func nothingReadableGivesNoReading() async {
        let (sampler, _, _, _) = make()
        #expect(await sampler.sample() == nil)
    }

    @Test func smcAloneIsAReadingWithNoGPU() async {
        let (sampler, smc, _, clock) = make()                    // GPU counter unavailable
        smc.next = SMCPower(systemWatts: 12, adapterWatts: 0, batteryWatts: 12)
        _ = await sampler.sample()
        clock.nanos = 1_000_000_000
        let reading = await sampler.sample()
        #expect(reading?.systemWatts == 12)
        #expect(reading?.gpuWatts == nil)
    }

    @Test func gpuAloneIsStillAReading() async {
        let (sampler, _, gpu, clock) = make()
        gpu.nanojoules = 0
        _ = await sampler.sample()
        gpu.nanojoules = 2_000_000_000
        clock.nanos = 1_000_000_000
        let reading = await sampler.sample()
        #expect(reading?.gpuWatts == 2)
        #expect(reading?.systemWatts == nil)
        // A second read at the same instant has no elapsed time: no rate, not infinity.
        gpu.nanojoules = 3_000_000_000
        #expect(await sampler.sample()?.gpuWatts == nil)
    }
}

struct SMCPowerTests {
    /// The SMC answers keys it doesn't really measure with 0 or junk (NaN, huge values); a
    /// laptop's battery key is negative on some Macs while discharging. Only a plausible
    /// magnitude counts as a reading.
    @Test func implausibleValuesAreNotReadings() {
        #expect(SMCPower.watts(15.3) == 15.3)
        #expect(SMCPower.watts(-4.5) == 4.5)
        #expect(SMCPower.watts(.nan) == nil)
        #expect(SMCPower.watts(.infinity) == nil)
        #expect(SMCPower.watts(5_000) == nil)
        #expect(SMCPower.watts(nil) == nil)
    }

    /// A Mac publishes some keys and not others (no battery on a desktop): each missing key is
    /// its own nil, and only a Mac with none of them has no SMC reading at all.
    @Test func missingKeysAreNilAndNoKeysIsNoReading() {
        #expect(SMCPower(rawSystem: 20, rawAdapter: 21, rawBattery: nil)
                == SMCPower(systemWatts: 20, adapterWatts: 21, batteryWatts: nil))
        #expect(SMCPower(rawSystem: nil, rawAdapter: nil, rawBattery: -3)?.batteryWatts == 3)
        #expect(SMCPower(rawSystem: nil, rawAdapter: .nan, rawBattery: nil) == nil)
    }

    /// The panel lists only what this Mac reports: no Battery row on a desktop, no GPU row
    /// when the counter is unavailable. System total always shows, as "—" until read.
    @Test func panelRowsHideWhatThisMacDoesNotReport() {
        let desktop = PowerReading(systemWatts: 30, adapterWatts: 31, batteryWatts: nil, gpuWatts: nil)
        #expect(EnergyPanel.facts(desktop) == [EnergyFact(label: "System total", value: "30.0 W"),
                                              EnergyFact(label: "From power adapter", value: "31.0 W")])
        let laptop = PowerReading(systemWatts: 12, adapterWatts: 0, batteryWatts: 12, gpuWatts: 1.5)
        #expect(EnergyPanel.facts(laptop).map(\.label)
                == ["System total", "From power adapter", "Battery, in or out", "GPU"])
        #expect(EnergyPanel.facts(laptop)[1].value == "0.0 W")         // on battery: shown as 0, not hidden
        #expect(EnergyPanel.facts(nil) == [EnergyFact(label: "System total", value: "—")])
    }

    @Test func fourCharacterCodesPackBigEndian() {
        #expect(SMCKey.code("PSTR") == 0x5053_5452)
    }

    @Test func scaleHasA10WattFloorThenFollowsThePeak() {
        var history = MetricHistory(capacity: 60)
        history.append(4)
        #expect(EnergyPanel.range(history).upperBound == 10)
        #expect(EnergyPanel.meterFraction(4, history: history) == 0.4)
        history.append(32)
        #expect(EnergyPanel.range(history).upperBound == 32)
        #expect(EnergyPanel.meterFraction(16, history: history) == 0.5)
        #expect(EnergyPanel.meterFraction(nil, history: history) == 0)
    }

    @Test func wattsText() {
        #expect(PowerReading.text(15.34) == "15.3 W")
        #expect(PowerReading.text(0.04) == "0.0 W")
        #expect(PowerReading.text(nil) == "—")
    }
}

@MainActor
struct VitalsModelPowerTests {
    @Test func eachReadingExtendsTheHistoryAndAMissingOneAddsNothing() async {
        let power = FakePowerSampler()
        let model = VitalsModel(sampler: FakeVitalsSampler(), thermalSampler: FakeThermalSampler(), powerSampler: power)
        power.next = PowerReading(systemWatts: 12, adapterWatts: nil, batteryWatts: nil, gpuWatts: 1)
        await model.refreshPowerOnce()
        power.next = nil
        await model.refreshPowerOnce()
        #expect(model.power == nil)
        #expect(model.powerHistory.values == [12])
    }

    @Test func energyPanelSitsBeforeBatteryOnlyWhenPowerIsReadable() {
        #expect(Surface.performance(hasGPU: true, hasThermal: true, hasEnergy: true, hasBattery: true)
                == [.cpu, .gpu, .memory, .network, .disk, .thermal, .energy, .battery])
        #expect(!Surface.performance(hasGPU: true, hasThermal: true, hasEnergy: false, hasBattery: true).contains(.energy))
        #expect(Surface.energy.metric == .energy)
        #expect(Surface.energy.title == "Energy")
    }
}

/// The real SMC on this Mac. Every Apple-silicon Mac publishes PSTR; a VM may not, which is
/// why the provider returns nil rather than crashing.
struct SMCPowerHardwareTests {
    @Test func thisMacReportsAPlausibleSystemPower() throws {
        let power = try #require(AppleSMCPower().read())
        let watts = try #require(power.systemWatts)
        #expect(watts > 0.5 && watts < 500)
    }
}
