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

    /// `run()` swallows the sleep's cancellation error, so the loop must exit on the
    /// `Task.isCancelled` check instead. Without that it would spin forever.
    @Test func runStopsSamplingAfterCancellation() async {
        let sampler = FakeVitalsSampler()
        let model = VitalsModel(sampler: sampler, interval: .milliseconds(10))

        let task = Task { await model.run() }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = await task.value

        let countAtCancel = sampler.callCount
        #expect(countAtCancel > 0, "loop should have sampled at least once before cancelling")

        try? await Task.sleep(for: .milliseconds(80))
        #expect(sampler.callCount == countAtCancel, "loop kept sampling after cancellation")
    }
}
