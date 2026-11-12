import Testing
import Foundation
@testable import macOSmonitor

final class FakeCoreLayout: CoreLayoutProviding, @unchecked Sendable {
    var layout: CoreLayout?
    func read() -> CoreLayout? { layout }
}

struct CoreLayoutTests {
    /// This Mac's shape (E cores first), but uneven, 2E + 3P, so counts can't be swapped
    /// unnoticed.
    private let layout = CoreLayout(kinds: [.efficiency, .efficiency, .performance, .performance, .performance])

    @Test func labelsNumberWithinEachKindInLogicalOrder() {
        #expect(CoreLayout.labels(for: layout, coreCount: 5) == ["E1", "E2", "P1", "P2", "P3"])
    }

    /// A mismatch must never put a P label on an E core: fall back to plain numbers.
    @Test func mismatchedOrUnknownLayoutFallsBackToNumbers() {
        #expect(CoreLayout.labels(for: layout, coreCount: 4) == ["0", "1", "2", "3"])
        #expect(CoreLayout.labels(for: nil, coreCount: 3) == ["0", "1", "2"])
    }

    @Test func countsAndSummary() {
        #expect(layout.count(.performance) == 3)
        #expect(layout.coreCountText == "5 (3P + 2E)")
    }

    /// E cores busy, P cores idle: a version that averaged the wrong kind, or all cores,
    /// gives a visibly different answer.
    @Test func averageLoadIsPerKind() {
        let perCore = [80.0, 60.0, 10.0, 0.0, 20.0]
        #expect(layout.averageLoad(of: .efficiency, perCore: perCore) == 70)
        #expect(layout.averageLoad(of: .performance, perCore: perCore) == 10)
        #expect(layout.averageLoad(of: .performance, perCore: [1, 2]) == nil)
    }

    @Test func buildsFromDeviceTreeEntriesInAnyOrder() {
        let cores = [(logicalID: 2, clusterType: "P"), (0, "E"), (1, "E")]
        #expect(CoreLayout(cores: cores)?.kinds == [.efficiency, .efficiency, .performance])
    }

    @Test func rejectsGapsAndUnknownTypes() {
        #expect(CoreLayout(cores: [(0, "E"), (2, "P")]) == nil)          // id 1 missing
        #expect(CoreLayout(cores: [(0, "E"), (1, "X")]) == nil)
        #expect(CoreLayout(cores: []) == nil)
    }

    /// Integration: this Mac's device tree agrees with the kernel's per-core count and the
    /// sysctl performance-level counts.
    @Test(.enabled(if: DeviceTreeCoreLayout().read() != nil))
    func readsThisMacsLayout() throws {
        let layout = try #require(DeviceTreeCoreLayout().read())
        let cores = try #require(HostStats().cpuTicks()).count
        #expect(layout.kinds.count == cores)

        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
        }
        // perflevel0 is the performance level, perflevel1 efficiency (when there are two).
        if sysctlInt("hw.nperflevels") == 2 {
            #expect(layout.count(.performance) == sysctlInt("hw.perflevel0.logicalcpu"))
            #expect(layout.count(.efficiency) == sysctlInt("hw.perflevel1.logicalcpu"))
        }
    }

    @MainActor
    @Test func vitalsModelReadsTheLayoutOnce() {
        let fake = FakeCoreLayout()
        fake.layout = layout
        let model = VitalsModel(coreLayoutProvider: fake)
        #expect(model.coreLayout == layout)
    }
}
