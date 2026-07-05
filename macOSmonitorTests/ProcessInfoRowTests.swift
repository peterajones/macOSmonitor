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

    @Test func matchesEmptyOrWhitespaceQueryReturnsTrue() {
        let row = ProcessInfoRow(pid: 42, name: "Safari", cpuPercent: nil, memoryBytes: nil)
        #expect(row.matches("") == true)
        #expect(row.matches("   ") == true)
    }

    @Test func matchesNameCaseInsensitiveSubstring() {
        let row = ProcessInfoRow(pid: 42, name: "Safari", cpuPercent: nil, memoryBytes: nil)
        #expect(row.matches("saf") == true)
        #expect(row.matches("ARI") == true)
        #expect(row.matches("chrome") == false)
    }

    @Test func matchesPIDSubstring() {
        let row = ProcessInfoRow(pid: 7712, name: "Safari", cpuPercent: nil, memoryBytes: nil)
        #expect(row.matches("771") == true)
        #expect(row.matches("7712") == true)
        #expect(row.matches("99") == false)
    }

    @Test func textPropertiesFallBackToDashWhenMissing() {
        let denied = ProcessInfoRow(pid: 1, name: "x", cpuPercent: nil, memoryBytes: nil)
        #expect(denied.cpuText == "—")
        #expect(denied.memoryText == "—")
    }

    @Test func cpuTextFormatsOneDecimalAndMemoryTextNonEmpty() {
        let row = ProcessInfoRow(pid: 1, name: "x", cpuPercent: 12.34, memoryBytes: 1024)
        #expect(row.cpuText == "12.3")
        #expect(row.memoryText.isEmpty == false)
    }

    @Test func cpuTimeTextAndSortKeyFallBackWhenNil() {
        let row = ProcessInfoRow(pid: 1, name: "x", cpuPercent: nil, memoryBytes: nil)
        #expect(row.cpuTimeText == "—")
        #expect(row.cpuTimeSortKey == 0)
    }

    @Test func cpuTimeTextFormatsSubHour() {
        let sub = ProcessInfoRow(pid: 1, name: "x", cpuPercent: nil, memoryBytes: nil,
                                 cpuTimeNanos: 3_030_000_000)              // 3.03s
        #expect(sub.cpuTimeText == "0:03.03")
        let mins = ProcessInfoRow(pid: 2, name: "y", cpuPercent: nil, memoryBytes: nil,
                                  cpuTimeNanos: 125_370_000_000)           // 2:05.37
        #expect(mins.cpuTimeText == "2:05.37")
    }

    @Test func cpuTimeTextRollsOverToHours() {
        let hour = ProcessInfoRow(pid: 3, name: "z", cpuPercent: nil, memoryBytes: nil,
                                  cpuTimeNanos: 5_025_000_000_000)          // 1:23:45
        #expect(hour.cpuTimeText == "1:23:45")
        #expect(hour.cpuTimeSortKey == 5_025_000_000_000)
    }

    @Test func cpuTimeTextDoesNotOverflowSecondsAtBoundary() {
        // 119.9996s must render as 2:00.00, never 1:60.00.
        let row = ProcessInfoRow(pid: 4, name: "b", cpuPercent: nil, memoryBytes: nil,
                                 cpuTimeNanos: 119_999_600_000)
        #expect(row.cpuTimeText == "2:00.00")
    }

    @Test func cpuTimeTextZeroAndExactHour() {
        let zero = ProcessInfoRow(pid: 5, name: "c", cpuPercent: nil, memoryBytes: nil,
                                  cpuTimeNanos: 0)
        #expect(zero.cpuTimeText == "0:00.00")
        let hour = ProcessInfoRow(pid: 6, name: "d", cpuPercent: nil, memoryBytes: nil,
                                  cpuTimeNanos: 3_600_000_000_000)
        #expect(hour.cpuTimeText == "1:00:00")
    }
}
