import Testing
import Foundation
@testable import macOSmonitor

final class FakeThermalSensors: ThermalSensorProviding, @unchecked Sendable {
    var readings: [SensorReading]?
    func read() -> [SensorReading]? { readings }
}

final class FakeThermalSampler: ThermalSampling, @unchecked Sendable {
    var next: ThermalReading?
    func sample() async -> ThermalReading? { next }
}

struct ThermalReadingTests {
    /// Shaped like this Mac's sensors. tcal is hotter than every die sensor and the
    /// placeholders (0, −127) are colder than all of them, so including either changes a
    /// figure visibly.
    private let readings = [
        SensorReading(name: "PMU tdie1", celsius: 44),
        SensorReading(name: "PMU tdie2", celsius: 40),
        SensorReading(name: "PMU tdie3", celsius: 48),
        SensorReading(name: "PMU tdie4", celsius: 0),        // placeholder: no value
        SensorReading(name: "PMU tdie5", celsius: -127),     // placeholder: no value
        SensorReading(name: "PMU tcal", celsius: 51.9),      // calibration, not a temperature
        SensorReading(name: "PMU tdev1", celsius: 38.3),
        SensorReading(name: "PMU tdev6", celsius: 40.3),
        SensorReading(name: "NAND CH0 temp", celsius: 36),
        SensorReading(name: "gas gauge battery", celsius: 32),
        SensorReading(name: "gas gauge battery", celsius: 33),
    ]

    @Test func groupsSensorsAndSkipsCalibrationAndPlaceholders() throws {
        let thermal = try #require(ThermalReading(readings: readings))
        #expect(thermal.cpuDieMax == 48)            // not tcal's 51.9
        #expect(thermal.cpuDieAverage == 44)        // (44 + 40 + 48) / 3, placeholders excluded
        #expect(thermal.boardMax == 40.3)
        #expect(thermal.ssd == 36)
        #expect(thermal.battery == 32.5)
        #expect(thermal.headline == 48)
    }

    @Test func noPlausibleReadingMeansNoPanel() {
        #expect(ThermalReading(readings: []) == nil)
        #expect(ThermalReading(readings: [SensorReading(name: "PMU tdie1", celsius: 0),
                                          SensorReading(name: "PMU tcal", celsius: 51.9)]) == nil)
    }

    /// Without die sensors the headline falls back to the hottest other group.
    @Test func headlineFallsBackWhenThereAreNoDieSensors() throws {
        let thermal = try #require(ThermalReading(readings: [SensorReading(name: "NAND CH0 temp", celsius: 36),
                                                             SensorReading(name: "PMU tdev2", celsius: 39)]))
        #expect(thermal.cpuDieMax == nil)
        #expect(thermal.headline == 39)
    }

    @Test func textRoundsToWholeDegrees() {
        #expect(ThermalReading.text(44.5) == "45 °C")
        #expect(ThermalReading.text(44.4) == "44 °C")
        #expect(ThermalReading.text(nil) == "—")
    }

    @Test func stripAndMeterFormatting() {
        #expect(SystemVitalsView.thermalText(state: "Nominal", celsius: 44.2) == "Nominal · 44 °C")
        #expect(SystemVitalsView.thermalText(state: "Nominal", celsius: nil) == "Nominal")
        #expect(ThermalPanel.meterFraction(44) == 0.44)
        #expect(ThermalPanel.meterFraction(130) == 1)
        #expect(ThermalPanel.meterFraction(nil) == 0)
    }

    @Test func thermalPanelSitsBeforeBatteryOnlyWhenSensorsAreReadable() {
        #expect(Surface.performance(hasGPU: true, hasThermal: true, hasBattery: true)
                == [.cpu, .gpu, .memory, .network, .disk, .thermal, .battery])
        #expect(!Surface.performance(hasGPU: true, hasThermal: false, hasBattery: true).contains(.thermal))
        #expect(Surface.thermal.metric == .thermal)
    }
}

struct ThermalSamplerTests {
    @Test func unavailableSensorsGiveNoReading() async {
        let sensors = FakeThermalSensors()
        sensors.readings = nil
        #expect(await ThermalSampler(sensors: sensors).sample() == nil)
    }

    @Test func groupsWhatTheSensorsReturn() async {
        let sensors = FakeThermalSensors()
        sensors.readings = [SensorReading(name: "PMU tdie1", celsius: 50)]
        #expect(await ThermalSampler(sensors: sensors).sample()?.cpuDieMax == 50)
    }

    /// Integration: this Mac's SMC sensors through the private HID interface.
    @Test(.enabled(if: HIDThermalSensors().read()?.isEmpty == false))
    func readsThisMacsSensors() throws {
        let readings = try #require(HIDThermalSensors().read())
        let thermal = try #require(ThermalReading(readings: readings))
        let die = try #require(thermal.cpuDieMax)
        #expect((20...110).contains(die), "CPU die \(die) °C")
    }
}

@MainActor
struct ThermalModelTests {
    @Test func historyRecordsTheHeadlineAndSkipsMissingReadings() async {
        let sampler = FakeThermalSampler()
        let model = VitalsModel(sampler: FakeVitalsSampler(), thermalSampler: sampler)

        sampler.next = ThermalReading(cpuDieMax: 47, cpuDieAverage: 44, boardMax: nil, ssd: nil, battery: nil)
        await model.refreshThermalOnce()
        sampler.next = nil                          // sensors briefly unavailable
        await model.refreshThermalOnce()
        sampler.next = ThermalReading(cpuDieMax: 52, cpuDieAverage: 49, boardMax: nil, ssd: nil, battery: nil)
        await model.refreshThermalOnce()

        #expect(model.thermalHistory.values == [47, 52])   // no fake 0 °C dip for the gap
        #expect(model.thermal?.cpuDieMax == 52)
        #expect(model.thermalHistory.capacity == 150)       // 5 minutes at 2 s
    }
}
