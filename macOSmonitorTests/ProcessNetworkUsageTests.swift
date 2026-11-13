import Testing
import Foundation
@testable import macOSmonitor

private func socket(_ pid: pid_t, _ localPort: UInt16, rx: UInt64, tx: UInt64) -> SocketTraffic {
    SocketTraffic(pid: pid, protocolName: "TCP",
                  local: SocketEndpoint(address: "127.0.0.1", port: localPort),
                  remote: SocketEndpoint(address: "140.82.112.3", port: 443),
                  counts: SocketCounts(rxBytes: rx, txBytes: tx))
}

struct ProcessNetworkUsageTests {
    @Test func totalsSumOnlyThisProcessesSockets() {
        let usage = ProcessNetworkUsage(pid: 10, readings: [socket(10, 50001, rx: 1_000, tx: 10),
                                                            socket(10, 50002, rx: 2_000, tx: 20),
                                                            socket(11, 50003, rx: 9_999, tx: 99)])
        #expect(usage.counts == SocketCounts(rxBytes: 3_000, txBytes: 30))
        #expect(usage.socketCount == 2)
    }

    @Test func rateCountsOnlySocketsOpenOnBothTicks() {
        let before = ProcessNetworkUsage(pid: 10, readings: [socket(10, 50001, rx: 1_000, tx: 100),
                                                             socket(10, 50002, rx: 5_000, tx: 500)])
        // 50002 closed (its 5 000 bytes would make the total drop); 50003 opened with 70 000
        // (counting it would spike the rate). Only 50001 moved: +3 000 rx, +1 000 tx in 2 s.
        let after = ProcessNetworkUsage(pid: 10, readings: [socket(10, 50001, rx: 4_000, tx: 1_100),
                                                            socket(10, 50003, rx: 70_000, tx: 0)])
        #expect(after.rates(since: before, seconds: 2) == SocketRates(rxPerSec: 1_500, txPerSec: 500))
    }

    @Test func aCounterThatGoesBackwardsIsLeftOutOfTheRate() {
        // Same ports, new socket (closed and reopened between ticks).
        let before = ProcessNetworkUsage(pid: 10, readings: [socket(10, 50001, rx: 9_000, tx: 9_000),
                                                             socket(10, 50002, rx: 1_000, tx: 1_000)])
        let after = ProcessNetworkUsage(pid: 10, readings: [socket(10, 50001, rx: 10, tx: 10),
                                                            socket(10, 50002, rx: 3_000, tx: 2_000)])
        #expect(after.rates(since: before, seconds: 1) == SocketRates(rxPerSec: 2_000, txPerSec: 1_000))
    }

    @Test func noSocketsReadsAsNone() {
        let usage = ProcessNetworkUsage(pid: 10, readings: [socket(11, 50001, rx: 1, tx: 1)])
        #expect(usage.socketCount == 0)
        #expect(usage.counts == SocketCounts(rxBytes: 0, txBytes: 0))
    }
}

@MainActor
struct ProcessListModelNetworkTests {
    final class FakeTraffic: SocketTrafficProviding, @unchecked Sendable {
        var next: [SocketTraffic]?
        func read() async -> [SocketTraffic]? { next }
    }

    final class Clock: @unchecked Sendable { var nanos: UInt64 = 0 }

    private func makeModel() -> (ProcessListModel, FakeTraffic, Clock) {
        let traffic = FakeTraffic()
        let clock = Clock()
        let model = ProcessListModel(sampler: FakeSampler(), networkProvider: traffic, now: { clock.nanos })
        return (model, traffic, clock)
    }

    @Test func selectedProcessGetsTotalsThenRates() async {
        let (model, traffic, clock) = makeModel()
        model.selectedPID = 10
        traffic.next = [socket(10, 50001, rx: 1_000, tx: 100)]
        clock.nanos = 1_000_000_000
        await model.refreshNetwork()
        #expect(model.selectedNetwork?.counts == SocketCounts(rxBytes: 1_000, txBytes: 100))
        #expect(model.selectedNetworkRates == nil)          // no baseline yet

        traffic.next = [socket(10, 50001, rx: 3_000, tx: 600)]
        clock.nanos = 3_000_000_000
        await model.refreshNetwork()
        #expect(model.selectedNetworkRates == SocketRates(rxPerSec: 1_000, txPerSec: 250))
    }

    @Test func aNewSelectionNeverTakesARateAgainstAnotherProcess() async {
        let (model, traffic, clock) = makeModel()
        traffic.next = [socket(10, 50001, rx: 1_000, tx: 100), socket(11, 50001, rx: 50_000, tx: 5_000)]
        model.selectedPID = 10
        clock.nanos = 1_000_000_000
        await model.refreshNetwork()
        model.selectedPID = 11                               // same local port, different process
        clock.nanos = 2_000_000_000
        await model.refreshNetwork()
        #expect(model.selectedNetwork?.counts == SocketCounts(rxBytes: 50_000, txBytes: 5_000))
        #expect(model.selectedNetworkRates == nil)
    }

    @Test func noSelectionOrNoFrameworkLeavesItEmpty() async {
        let (model, traffic, _) = makeModel()
        traffic.next = [socket(10, 50001, rx: 1, tx: 1)]
        await model.refreshNetwork()                          // nothing selected
        #expect(model.selectedNetwork == nil)

        model.selectedPID = 10
        traffic.next = nil                                    // framework missing
        await model.refreshNetwork()
        #expect(model.selectedNetwork == nil)
        #expect(model.isNetworkAvailable == false)
    }
}
