import Testing
@testable import macOSmonitor

struct NetworkBreakdownTests {
    private let ports: [String: HardwarePort] = [
        "en0": HardwarePort(displayName: "Wi-Fi", kind: .wifi),
        "en6": HardwarePort(displayName: "USB 10/100/1000 LAN", kind: .ethernet),
        "en8": HardwarePort(displayName: "Ethernet Adapter (en8)", kind: .ethernet),
        "bridge0": HardwarePort(displayName: "Thunderbolt Bridge", kind: .otherHardware),
        "en1": HardwarePort(displayName: "Thunderbolt 1", kind: .otherHardware),
    ]

    private func counters(_ names: String...) -> [InterfaceCounters] {
        names.map { InterfaceCounters(name: $0, received: 1, sent: 1) }
    }

    @Test func rowsAreOrderedByKindThenNameRegardlessOfInputOrRate() {
        let rows = NetworkBreakdown.rows(
            counters: counters("bridge0", "en6", "awdl0", "en8", "en0"),
            rates: ["en6": (in: 900, out: 900), "en0": (in: 1, out: 1), "awdl0": (in: 5_000, out: 0)],
            ports: ports)

        #expect(rows.map(\.name) == ["Wi-Fi", "Ethernet Adapter (en8)", "USB 10/100/1000 LAN",
                                     "Thunderbolt Bridge", "Other"])
    }

    @Test func interfacesWithoutAHardwarePortFoldIntoOneOtherRow() {
        let rows = NetworkBreakdown.rows(
            counters: counters("en0", "awdl0", "utun4"),
            rates: ["en0": (in: 10, out: 20), "awdl0": (in: 300, out: 7), "utun4": (in: 40, out: 1_000)],
            ports: ports)

        #expect(rows == [
            InterfaceRate(name: "Wi-Fi", kind: .wifi, inBytesPerSec: 10, outBytesPerSec: 20),
            InterfaceRate(name: "Other", kind: .virtual, inBytesPerSec: 340, outBytesPerSec: 1_007),
        ])
    }

    @Test func portsThatNeverCarriedTrafficAreHiddenButIdleOnesStay() {
        let rows = NetworkBreakdown.rows(
            counters: [InterfaceCounters(name: "en0", received: 5_000, sent: 0),    // idle now, used before
                       InterfaceCounters(name: "en1", received: 0, sent: 0)],       // never used
            rates: [:],
            ports: ports)

        #expect(rows == [InterfaceRate(name: "Wi-Fi", kind: .wifi, inBytesPerSec: 0, outBytesPerSec: 0)])
    }

    @Test func otherRowIsOmittedWhenVirtualInterfacesNeverCarriedTraffic() {
        let rows = NetworkBreakdown.rows(
            counters: [InterfaceCounters(name: "en0", received: 1, sent: 1),
                       InterfaceCounters(name: "utun0", received: 0, sent: 0)],
            rates: ["en0": (in: 1, out: 1)],
            ports: ports)

        #expect(rows.map(\.name) == ["Wi-Fi"])
    }
}
