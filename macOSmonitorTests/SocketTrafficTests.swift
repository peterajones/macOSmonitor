import Testing
import Foundation
import Darwin
@testable import macOSmonitor

/// A sockaddr as NetworkStatistics hands it over: the raw struct bytes in a CFData.
private func sockaddrV4(_ address: String, _ port: UInt16) -> Data {
    var sa = sockaddr_in()
    sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sa.sin_family = sa_family_t(AF_INET)
    sa.sin_port = port.bigEndian
    inet_pton(AF_INET, address, &sa.sin_addr)
    return withUnsafeBytes(of: &sa) { Data($0) }
}

private func sockaddrV6(_ address: String, _ port: UInt16) -> Data {
    var sa = sockaddr_in6()
    sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    sa.sin6_family = sa_family_t(AF_INET6)
    sa.sin6_port = port.bigEndian
    inet_pton(AF_INET6, address, &sa.sin6_addr)
    return withUnsafeBytes(of: &sa) { Data($0) }
}

private func portRow(pid: pid_t = 10, proto: String = "TCP", local: String = "127.0.0.1", _ localPort: UInt16,
                     remote: String? = nil, _ remotePort: UInt16? = nil) -> PortRow {
    PortRow(id: "\(pid)|\(localPort)|\(remotePort ?? 0)", pid: pid, processName: "node",
            port: ProcessPort(protocolName: proto, localAddress: local, localPort: localPort,
                              remoteAddress: remote, remotePort: remotePort, state: remote == nil ? "LISTEN" : "ESTABLISHED"))
}

struct SocketTrafficTests {
    // MARK: - Address parsing

    @Test func parsesIPv4AndIPv6Endpoints() {
        #expect(SocketEndpoint(sockaddr: sockaddrV4("140.82.112.3", 443)) == SocketEndpoint(address: "140.82.112.3", port: 443))
        #expect(SocketEndpoint(sockaddr: sockaddrV6("2606:4700::1111", 853)) == SocketEndpoint(address: "2606:4700::1111", port: 853))
    }

    @Test func wildcardAddressReadsAsStarLikeTheSocketTable() {
        #expect(SocketEndpoint(sockaddr: sockaddrV4("0.0.0.0", 5353))?.address == "*")
        #expect(SocketEndpoint(sockaddr: sockaddrV6("::", 5353))?.address == "*")
    }

    @Test func garbageIsNotAnEndpoint() {
        #expect(SocketEndpoint(sockaddr: Data([1, 2, 3])) == nil)
        #expect(SocketEndpoint(sockaddr: Data(repeating: 0, count: 16)) == nil)   // family 0
    }

    // MARK: - Matching a socket to its row

    @Test func trafficKeyMatchesTheRowForTheSameSocket() {
        let traffic = SocketTraffic(pid: 10, protocolName: "TCP",
                                    local: SocketEndpoint(address: "127.0.0.1", port: 52000),
                                    remote: SocketEndpoint(address: "140.82.112.3", port: 443),
                                    counts: SocketCounts(rxBytes: 1, txBytes: 2))
        #expect(traffic.key == portRow(52000, remote: "140.82.112.3", 443).trafficKey)
        // Another process, protocol, port or peer is a different socket.
        #expect(traffic.key != portRow(pid: 11, 52000, remote: "140.82.112.3", 443).trafficKey)
        #expect(traffic.key != portRow(proto: "UDP", 52000, remote: "140.82.112.3", 443).trafficKey)
        #expect(traffic.key != portRow(52001, remote: "140.82.112.3", 443).trafficKey)
        #expect(traffic.key != portRow(52000, remote: "140.82.112.4", 443).trafficKey)
    }

    @Test func unconnectedPeerMatchesARowWithNoRemote() {
        // The framework reports an unconnected peer as 0.0.0.0:0; the socket table as none.
        let traffic = SocketTraffic(pid: 10, protocolName: "UDP",
                                    local: SocketEndpoint(address: "*", port: 5353),
                                    remote: SocketEndpoint(address: "*", port: 0),
                                    counts: SocketCounts(rxBytes: 1, txBytes: 2))
        #expect(traffic.key == portRow(proto: "UDP", local: "*", 5353).trafficKey)
    }

    @Test func ipv4MappedPeerMatchesItsPlainIPv4Form() {
        // A dual-stack socket's peer can come back as ::ffff:a.b.c.d from one API and
        // a.b.c.d from the other.
        let traffic = SocketTraffic(pid: 10, protocolName: "TCP",
                                    local: SocketEndpoint(address: "*", port: 52000),
                                    remote: SocketEndpoint(address: "::ffff:140.82.112.3", port: 443),
                                    counts: SocketCounts(rxBytes: 1, txBytes: 2))
        #expect(traffic.key == portRow(52000, remote: "140.82.112.3", 443).trafficKey)
    }

    // MARK: - Text

    @Test func rowTextShowsTotalAndRate() {
        var row = portRow(52000, remote: "140.82.112.3", 443)
        #expect(row.receivedText == "—")
        row.counts = SocketCounts(rxBytes: 18_500_000, txBytes: 0)
        row.rates = SocketRates(rxPerSec: 2_100, txPerSec: 0)
        #expect(row.receivedText == "18.5 MB  ·  \(SystemVitals.rate(2_100))")
        #expect(row.sentText == "Zero KB  ·  \(SystemVitals.rate(0))")
    }
}

@MainActor
struct PortsModelTrafficTests {
    final class FixedSampler: PortsSampling, @unchecked Sendable {
        var rows: [PortRow] = []
        func sample() async -> [PortRow] { rows }
    }

    final class FakeTraffic: SocketTrafficProviding, @unchecked Sendable {
        var next: [SocketTraffic]?
        func read() async -> [SocketTraffic]? { next }
    }

    final class Clock: @unchecked Sendable {
        var nanos: UInt64 = 0
    }

    private func traffic(_ rx: UInt64, _ tx: UInt64) -> SocketTraffic {
        SocketTraffic(pid: 10, protocolName: "TCP",
                      local: SocketEndpoint(address: "127.0.0.1", port: 52000),
                      remote: SocketEndpoint(address: "140.82.112.3", port: 443),
                      counts: SocketCounts(rxBytes: rx, txBytes: tx))
    }

    private func makeModel() -> (PortsModel, FakeTraffic, Clock) {
        let sampler = FixedSampler()
        sampler.rows = [portRow(52000, remote: "140.82.112.3", 443), portRow(3000)]
        let source = FakeTraffic()
        let clock = Clock()
        let model = PortsModel(sampler: sampler, dns: ReverseDNS(lookup: FakeHostLookup()),
                               traffic: source, now: { clock.nanos })
        return (model, source, clock)
    }

    @Test func countsLandOnTheirRowAndRatesNeedTwoTicks() async {
        let (model, source, clock) = makeModel()
        source.next = [traffic(1_000, 400)]
        clock.nanos = 1_000_000_000
        await model.refreshOnce()
        #expect(model.rows[0].counts == SocketCounts(rxBytes: 1_000, txBytes: 400))
        #expect(model.rows[0].rates == nil)            // no baseline yet
        #expect(model.rows[1].counts == nil)           // no traffic reported for the listener

        source.next = [traffic(4_000, 1_400)]
        clock.nanos = 3_000_000_000                    // two seconds later
        await model.refreshOnce()
        #expect(model.rows[0].rates == SocketRates(rxPerSec: 1_500, txPerSec: 500))
        #expect(model.isTrafficAvailable)
    }

    @Test func aCounterThatGoesBackwardsGivesNoRate() async {
        // A socket closed and a new one opened on the same ports between ticks.
        let (model, source, clock) = makeModel()
        source.next = [traffic(5_000, 5_000)]
        clock.nanos = 1_000_000_000
        await model.refreshOnce()
        source.next = [traffic(100, 100)]
        clock.nanos = 2_000_000_000
        await model.refreshOnce()
        #expect(model.rows[0].counts == SocketCounts(rxBytes: 100, txBytes: 100))
        #expect(model.rows[0].rates == nil)
    }

    @Test func unavailableFrameworkLeavesRowsWithoutCounts() async {
        let (model, source, _) = makeModel()
        source.next = nil
        await model.refreshOnce()
        #expect(model.isTrafficAvailable == false)
        #expect(model.rows.allSatisfy { $0.counts == nil })
        #expect(model.rows.count == 2)
    }
}

/// Against the real framework: bytes this test sends over loopback must be counted.
struct SocketTrafficIntegrationTests {
    @Test func countsBytesThisProcessSends() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try #require(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        } == 0)
        try #require(listen(listener, 1) == 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }
        try #require(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
        } == 0)
        let server = accept(listener, nil, nil)
        try #require(server >= 0)
        defer { close(server) }

        let payload = [UInt8](repeating: 7, count: 50_000)
        var sent = 0
        while sent < payload.count {
            let n = payload[sent...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            try #require(n > 0)
            sent += n
            var sink = [UInt8](repeating: 0, count: 65_536)
            _ = read(server, &sink, sink.count)
        }

        // Sources register asynchronously once the manager starts, so poll briefly (the app's
        // next tick is 2 s later anyway).
        let reader = NStatSocketTraffic()
        let serverPort = UInt16(bigEndian: address.sin_port)
        var ours: [SocketTraffic] = []
        var all: [SocketTraffic] = []
        for _ in 0..<30 {
            all = try #require(await reader.read(), "NetworkStatistics unavailable")
            ours = all.filter { $0.pid == getpid() && $0.protocolName == "TCP" && $0.remote?.port == serverPort }
            if ours.contains(where: { $0.counts.txBytes >= 50_000 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ours.contains { $0.counts.txBytes >= 50_000 },
                "found \(ours) among \(all.count) sockets")
    }
}
