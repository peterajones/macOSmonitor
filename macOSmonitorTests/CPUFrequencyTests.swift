import Testing
import Foundation
@testable import macOSmonitor

final class FakeFrequencies: CPUFrequencyProviding, @unchecked Sendable {
    var next: [String: CoreFrequency]?
    func read() -> [String: CoreFrequency]? { next }
}

struct CPUFrequencyMathTests {
    /// Idle half the time, then 30 ticks at 1000 MHz and 20 at 3000 MHz. Time-weighted that's
    /// 1800 MHz; a plain average of the two steps would say 2000.
    @Test func coreAverageIsWeightedByTimeAtEachStep() throws {
        let core = try #require(CPUFrequencyMath.core(residencies: [50, 30, 20], table: [1000, 3000]))
        #expect(core.activeFraction == 0.5)
        #expect(core.averageMHz == 1800)
    }

    /// A count mismatch would make every figure silently wrong, so it shows nothing.
    @Test func mismatchedOrBrokenResidenciesGiveNothing() {
        #expect(CPUFrequencyMath.core(residencies: [50, 30], table: [1000, 3000]) == nil)
        #expect(CPUFrequencyMath.core(residencies: [50, -1, 20], table: [1000, 3000]) == nil)
        #expect(CPUFrequencyMath.core(residencies: [0, 0, 0], table: [1000, 3000]) == nil)
    }

    @Test func aCoreThatNeverLeftIdleHasNoClock() throws {
        let core = try #require(CPUFrequencyMath.core(residencies: [100, 0, 0], table: [1000, 3000]))
        #expect(core.activeFraction == 0)
        #expect(core.averageMHz == nil)
        #expect(core.text == "idle")
    }

    /// Busy core at 3000, barely-active core at 1000: weighted 2800, unweighted 2000. The idle
    /// core's absent clock must not drag it down either.
    @Test func groupAverageIsWeightedByActivity() {
        let cores = [CoreFrequency(activeFraction: 0.9, averageMHz: 3000),
                     CoreFrequency(activeFraction: 0.1, averageMHz: 1000),
                     CoreFrequency(activeFraction: 0, averageMHz: nil)]
        #expect(CPUFrequencyMath.groupAverageMHz(cores) == 2800)
        #expect(CPUFrequencyMath.groupAverageMHz([CoreFrequency(activeFraction: 0, averageMHz: nil)]) == nil)
    }

    /// Shaped like the device tree: 8-byte entries, little-endian Hz then voltage, with a
    /// stray trailing byte that must be ignored.
    @Test func parsesDeviceTreeFrequencyTables() {
        func entry(_ hz: UInt32, _ microvolts: UInt32) -> [UInt8] {
            withUnsafeBytes(of: hz.littleEndian, Array.init) + withUnsafeBytes(of: microvolts.littleEndian, Array.init)
        }
        let data = Data(entry(744_000_000, 600_000) + entry(2_748_000_000, 900_000) + [0xFF])
        #expect(CPUFrequencyMath.megahertz(fromVoltageStates: data) == [744, 2748])
    }

    @Test func channelNamesMapToCoreGridLabels() {
        #expect(CPUFrequencyMath.label(forChannel: "ECPU0") == "E1")
        #expect(CPUFrequencyMath.label(forChannel: "PCPU5") == "P6")
        #expect(CPUFrequencyMath.label(forChannel: "GPUPH") == nil)
        #expect(CPUFrequencyMath.label(forChannel: "ECPUDTL00") == nil)
        #expect(CPUFrequencyMath.label(forChannel: "PCPU") == nil)
    }

    @Test func formatting() {
        #expect(CoreFrequency.text(mhz: 3456) == "3.5 GHz")
        #expect(CoreFrequency.text(mhz: 820.4) == "820 MHz")
        let freqs = ["P1": CoreFrequency(activeFraction: 0.9, averageMHz: 3000),
                     "P2": CoreFrequency(activeFraction: 0.1, averageMHz: 1000),
                     "E1": CoreFrequency(activeFraction: 0, averageMHz: nil)]
        #expect(CPUPanel.clusterClock(freqs, prefix: "P") == "~2.8 GHz")
        #expect(CPUPanel.clusterClock(freqs, prefix: "E") == "idle")
        #expect(CPUPanel.clusterClock([:], prefix: "P") == "—")
    }
}

struct CPUFrequencySamplingTests {
    @Test func samplerPublishesFrequenciesOrNothing() async {
        let fake = FakeFrequencies()
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: FakeNetworkStats(),
                                          battery: FakeBatteryStats(), gpu: FakeGPUStats(), frequencies: fake)
        fake.next = ["P1": CoreFrequency(activeFraction: 0.5, averageMHz: 3200)]
        #expect(await sampler.sample().coreFrequencies == fake.next)
        fake.next = nil
        #expect(await sampler.sample().coreFrequencies.isEmpty)
    }

    /// Integration: this Mac's IOReport and device-tree tables, without root. The first read
    /// only sets the baseline; the second gives a clock for cores labelled like the grid.
    @Test(.enabled(if: DeviceTreeCoreLayout().read() != nil))
    func readsThisMacsCoreClocks() async throws {
        let provider = IOReportCPUFrequencies()
        #expect(provider.read() == nil)
        try await Task.sleep(for: .milliseconds(300))
        let frequencies = try #require(provider.read())
        let layout = try #require(DeviceTreeCoreLayout().read())
        #expect(Set(frequencies.keys) == Set(CoreLayout.labels(for: layout, coreCount: layout.kinds.count)))
        for (label, core) in frequencies {
            #expect((0...1).contains(core.activeFraction), "\(label)")
            if let mhz = core.averageMHz { #expect((500...4500).contains(mhz), "\(label) \(mhz) MHz") }
        }
    }
}
