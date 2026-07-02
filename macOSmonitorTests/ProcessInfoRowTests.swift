import Testing
@testable import macOSmonitor

struct ProcessInfoRowTests {
    @Test func idEqualsPid() {
        let row = ProcessInfoRow(pid: 99, name: "x", cpuPercent: 1, memoryBytes: 1)
        #expect(row.id == 99)
    }

    @Test func sortKeysUseSentinelsWhenDetailMissing() {
        let denied = ProcessInfoRow(pid: 5, name: "x", cpuPercent: nil, memoryBytes: nil)
        #expect(denied.cpuSortKey == -1)
        #expect(denied.memSortKey == 0)
    }

    @Test func sortKeysPassThroughRealValues() {
        let live = ProcessInfoRow(pid: 6, name: "y", cpuPercent: 3.5, memoryBytes: 100)
        #expect(live.cpuSortKey == 3.5)
        #expect(live.memSortKey == 100)
    }

    @Test func ownedRowCanTerminate() {
        let owned = ProcessInfoRow(pid: 1, name: "mine", cpuPercent: nil, memoryBytes: 4096)
        #expect(owned.canTerminate == true)
    }

    @Test func deniedRowCannotTerminate() {
        let denied = ProcessInfoRow(pid: 2, name: "theirs", cpuPercent: nil, memoryBytes: nil)
        #expect(denied.canTerminate == false)
    }
}
