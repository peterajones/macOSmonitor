import Testing
import Foundation
@testable import macOSmonitor

final class FakeGPUStats: GPUStatsProviding, @unchecked Sendable {
    var info: GPUInfo?
    func read() -> GPUInfo? { info }
}

struct GPUStatsTests {
    /// Shaped like this Mac's AGXAccelerator entry.
    private let properties: [String: Any] = [
        "model": "Apple M3 Pro",
        "gpu-core-count": NSNumber(value: 18),
        "PerformanceStatistics": [
            "Device Utilization %": NSNumber(value: 18),
            "Renderer Utilization %": NSNumber(value: 11),     // a different figure: must not be used
            "In use system memory": NSNumber(value: 1_180_123_136 as UInt64),
            "Alloc system memory": NSNumber(value: 5_606_359_040 as UInt64),   // nor this one
        ] as [String: Any],
    ]

    @Test func parsesUtilisationMemoryNameAndCores() throws {
        let gpu = try #require(GPUInfo(properties: properties))
        #expect(gpu.utilizationPercent == 18)
        #expect(gpu.memoryInUseBytes == 1_180_123_136)
        #expect(gpu.utilizationText == "18%")
        #expect(gpu.descriptionText == "Apple M3 Pro, 18 cores")
    }

    @Test func noUtilisationMeansNoUsableGPU() {
        #expect(GPUInfo(properties: ["model": "Virtual GPU"]) == nil)
    }

    @Test func utilisationIsClampedToAPercentage() {
        var over = properties
        over["PerformanceStatistics"] = ["Device Utilization %": NSNumber(value: 140)]
        #expect(GPUInfo(properties: over)?.utilizationPercent == 100)
        #expect(GPUInfo(properties: over)?.memoryInUseBytes == nil)
    }

    @Test func descriptionUsesWhateverIsKnown() {
        #expect(GPUInfo(utilizationPercent: 0, memoryInUseBytes: nil, name: "Apple M3 Pro").descriptionText == "Apple M3 Pro")
        #expect(GPUInfo(utilizationPercent: 0, memoryInUseBytes: nil, coreCount: 10).descriptionText == "10 GPU cores")
        #expect(GPUInfo(utilizationPercent: 0, memoryInUseBytes: nil).descriptionText == "GPU")
    }

    /// Integration: this Mac's GPU publishes statistics without root.
    @Test(.enabled(if: GPUStats().read() != nil))
    func readsThisMacsGPU() throws {
        let gpu = try #require(GPUStats().read())
        #expect((0...100).contains(gpu.utilizationPercent))
        #expect((gpu.memoryInUseBytes ?? 0) > 0)
        #expect(gpu.name?.isEmpty == false)
    }

    @Test func samplerPublishesTheGPUAndHistoryRecordsIt() async {
        let fake = FakeGPUStats()
        fake.info = GPUInfo(utilizationPercent: 37, memoryInUseBytes: 2_000)
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: FakeNetworkStats(),
                                          battery: FakeBatteryStats(), gpu: fake)
        let first = await sampler.sample()
        #expect(first.gpu == fake.info)
        #expect(first.gpuText == "37%")

        fake.info = nil                               // statistics vanish (e.g. driver reset)
        let second = await sampler.sample()
        #expect(second.gpu == nil)
        #expect(second.gpuText == "—")

        var history = VitalsHistory(capacity: 60)
        history.append(first)
        history.append(second)
        #expect(history.gpu.values == [37, 0])         // a gap reads 0, keeping series aligned
        #expect(history.gpu.values.count == history.cpu.values.count)
    }

    @Test func gpuPanelIsListedAfterCPUOnlyWhenPresent() {
        #expect(Surface.performance(hasGPU: true, hasBattery: true)
                == [.cpu, .gpu, .memory, .network, .disk, .battery])
        #expect(Surface.performance(hasGPU: false, hasBattery: false)
                == [.cpu, .memory, .network, .disk])
        #expect(Surface.gpu.metric == .gpu)
    }
}
