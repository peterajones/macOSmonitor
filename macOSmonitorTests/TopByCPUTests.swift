import Testing
import Darwin
@testable import macOSmonitor

struct TopByCPUTests {
    private func row(_ pid: pid_t, _ cpu: Double?) -> ProcessInfoRow {
        ProcessInfoRow(pid: pid, name: "p\(pid)", cpuPercent: cpu, memoryBytes: 1)
    }

    @Test func ordersByCPUDescending() {
        let rows = [row(1, 5), row(2, 90), row(3, 40)]
        let top = ProcessInfoRow.topByCPU(rows, limit: 3)
        #expect(top.map(\.pid) == [2, 3, 1])
    }

    @Test func honoursTheLimit() {
        let rows = [row(1, 5), row(2, 90), row(3, 40)]
        #expect(ProcessInfoRow.topByCPU(rows, limit: 2).map(\.pid) == [2, 3])
    }

    @Test func limitLargerThanInputReturnsEverything() {
        let rows = [row(1, 5), row(2, 90)]
        #expect(ProcessInfoRow.topByCPU(rows, limit: 99).count == 2)
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(ProcessInfoRow.topByCPU([], limit: 8).isEmpty)
    }

    @Test func nonPositiveLimitReturnsEmpty() {
        #expect(ProcessInfoRow.topByCPU([row(1, 5)], limit: 0).isEmpty)
        #expect(ProcessInfoRow.topByCPU([row(1, 5)], limit: -3).isEmpty)
    }

    /// Deterministic tie order stops the card reshuffling every tick when many
    /// processes sit at exactly 0%.
    @Test func tiesBreakByAscendingPID() {
        let rows = [row(9, 0), row(3, 0), row(7, 0)]
        #expect(ProcessInfoRow.topByCPU(rows, limit: 3).map(\.pid) == [3, 7, 9])
    }

    /// A denied process reports nil CPU and must sink below any readable process.
    @Test func unreadableCPUSinksToTheBottom() {
        let rows = [row(1, nil), row(2, 0)]
        #expect(ProcessInfoRow.topByCPU(rows, limit: 2).map(\.pid) == [2, 1])
    }
}
