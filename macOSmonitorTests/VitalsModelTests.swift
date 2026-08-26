import Foundation
import Testing
@testable import macOSmonitor

final class FakeVitalsSampler: SystemVitalsSampling, @unchecked Sendable {
    var next = SystemVitals(cpuUsagePercent: 5, usedMemoryBytes: 1, totalMemoryBytes: 2,
                            coreCount: 8, activeCoreCount: 8, thermalState: "Nominal",
                            lowPowerMode: false, uptime: 1, osVersion: "macOS 26.5")
    var callCount = 0
    func sample() async -> SystemVitals { callCount += 1; return next }
}

@MainActor
struct VitalsModelTests {
    @Test func refreshOncePublishesVitals() async {
        let model = VitalsModel(sampler: FakeVitalsSampler())
        #expect(model.vitals == nil)
        await model.refreshOnce()
        #expect(model.vitals?.coreCount == 8)
    }

    @Test func refreshOnceAppendsToHistory() async {
        let fake = FakeVitalsSampler()
        let model = VitalsModel(sampler: fake)
        #expect(model.history.cpu.values.isEmpty)

        await model.refreshOnce()
        await model.refreshOnce()

        #expect(model.history.cpu.values == [5, 5])
        #expect(model.history.memoryUsed.values.count == 2)
    }

    @Test func historyIsCappedAtSixtySamples() async {
        let model = VitalsModel(sampler: FakeVitalsSampler())
        for _ in 0..<65 { await model.refreshOnce() }
        #expect(model.history.cpu.values.count == 60)
    }
}
