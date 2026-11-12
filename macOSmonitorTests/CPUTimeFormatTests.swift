import Testing
@testable import macOSmonitor

struct CPUTimeFormatTests {
    private let threeSeconds: UInt64 = 3_030_000_000          // 3.03 s
    private let twoMinutes: UInt64 = 125_370_000_000          // 2:05.37
    private let overAnHour: UInt64 = 5_025_000_000_000        // 1:23:45
    /// 119.9996 s: rounds to 120.00 s. A format that rounds each field separately reads
    /// "1:60.00", "1m 60s" or "119.100 s".
    private let roundsUp: UInt64 = 119_999_600_000

    private func strings(_ format: CPUTimeFormat) -> [String] {
        [threeSeconds, twoMinutes, overAnHour, roundsUp].map { format.string(nanos: $0) }
    }

    @Test func activityMonitorFormatIsUnchanged() {
        #expect(strings(.adaptive) == ["0:03.03", "2:05.37", "1:23:45", "2:00.00"])
    }

    @Test func hoursFormatIsAlwaysHMMSS() {
        #expect(strings(.hours) == ["0:00:03", "0:02:05", "1:23:45", "0:02:00"])
    }

    @Test func secondsFormatIsTotalSecondsWithHundredths() {
        #expect(strings(.seconds) == ["3.03 s", "125.37 s", "5025.00 s", "120.00 s"])
    }

    @Test func compactFormatSpellsOutUnits() {
        #expect(strings(.compact) == ["3.03s", "2m 05s", "1h 23m 45s", "2m 00s"])
    }

    @Test func unreadableIsADashInEveryFormat() {
        for format in CPUTimeFormat.allCases {
            #expect(format.string(nanos: nil) == "—")
        }
    }

    /// The row's default text stays Activity Monitor's, and the formatted variant delegates.
    @Test func rowUsesTheChosenFormat() {
        let row = ProcessInfoRow(pid: 1, name: "x", cpuPercent: nil, memoryBytes: nil, cpuTimeNanos: twoMinutes)
        #expect(row.cpuTimeText == "2:05.37")
        #expect(row.cpuTimeText(.compact) == "2m 05s")
    }

    /// @AppStorage stores the raw value; renaming a case would silently reset the choice.
    @Test func storedNamesAreStable() {
        #expect(CPUTimeFormat.allCases.map(\.rawValue) == ["adaptive", "hours", "seconds", "compact"])
    }
}
