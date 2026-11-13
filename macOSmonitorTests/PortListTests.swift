import Testing
import Darwin
@testable import macOSmonitor

/// Ports per PID, unlike `FakePortProvider`, which returns one list for every process.
final class FakePortsByPID: ProcessPortProviding, @unchecked Sendable {
    var ports: [pid_t: [ProcessPort]] = [:]
    func ports(pid: pid_t) -> [ProcessPort] { ports[pid] ?? [] }
}

private func tcp(_ local: UInt16, remote: (String, UInt16)? = nil, state: String) -> ProcessPort {
    ProcessPort(protocolName: "TCP", localAddress: "127.0.0.1", localPort: local,
                remoteAddress: remote?.0, remotePort: remote?.1, state: state)
}

private func udp(_ local: UInt16, remote: (String, UInt16)? = nil) -> ProcessPort {
    ProcessPort(protocolName: "UDP", localAddress: "*", localPort: local,
                remoteAddress: remote?.0, remotePort: remote?.1, state: nil)
}

private func row(_ pid: pid_t, _ name: String, _ port: ProcessPort) -> PortRow {
    PortRow(id: "\(pid)", pid: pid, processName: name, port: port)
}

struct PortListTests {
    // MARK: - Sampler

    @Test func samplerListsEverySocketWithItsProcessListeningFirst() async {
        let procs = FakeProcInfo()
        procs.pids = [10, 20, 30]
        procs.names = [10: "node", 20: "Safari", 30: "idle"]
        let ports = FakePortsByPID()
        // An inbound SSH session sits on local port 22: a sort by port alone would put it first.
        ports.ports = [10: [tcp(22, remote: ("10.0.0.9", 51000), state: "ESTABLISHED"), tcp(3000, state: "LISTEN")],
                       20: [tcp(443, state: "LISTEN"), udp(5353)]]
        let sampler = PortsSampler(procInfo: procs, ports: ports)

        let rows = await sampler.sample()
        // Listening (TCP LISTEN, or UDP with no peer) first, each group by local port.
        #expect(rows.map(\.port.localPort) == [443, 3000, 5353, 22])
        #expect(rows.map(\.processName) == ["Safari", "node", "Safari", "node"])
        #expect(rows.map(\.pid) == [20, 10, 20, 10])
    }

    /// macOS withholds other users' and root's descriptors, so `ports(pid:)` returns nothing
    /// for them. Such a process adds no rows, and the processes after it are still listed.
    @Test func aProcessWithWithheldDescriptorsIsSkippedNotFatal() async {
        let procs = FakeProcInfo()
        procs.pids = [10, 20, 30]
        procs.names = [10: "node", 20: "mDNSResponder", 30: "Safari"]
        let ports = FakePortsByPID()
        ports.ports = [10: [tcp(3000, state: "LISTEN")], 30: [tcp(443, state: "LISTEN")]]   // 20 withheld
        let rows = await PortsSampler(procInfo: procs, ports: ports).sample()
        #expect(rows.map(\.pid) == [30, 10])
        #expect(!rows.contains { $0.processName == "mDNSResponder" })
    }

    @Test func identicalSocketsStillGetDistinctIDs() async {
        // SO_REUSEPORT lets one process hold the same port twice; a Table with duplicate IDs
        // misdraws rows.
        let procs = FakeProcInfo()
        procs.pids = [10]
        let ports = FakePortsByPID()
        ports.ports = [10: [udp(5353), udp(5353)]]
        let rows = await PortsSampler(procInfo: procs, ports: ports).sample()
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
    }

    // MARK: - Row text and matching

    @Test func rowTextShowsAddressesAndDashesForWhatIsMissing() {
        let connected = row(1, "node", tcp(52000, remote: ("1.2.3.4", 443), state: "ESTABLISHED"))
        #expect(connected.localText == "127.0.0.1:52000")
        #expect(connected.remoteText == "1.2.3.4:443")
        #expect(connected.stateText == "ESTABLISHED")

        let bound = row(1, "mDNSResponder", udp(5353))
        #expect(bound.localText == "*:5353")
        #expect(bound.remoteText == "—")
        #expect(bound.stateText == "—")
    }

    @Test func searchMatchesNamePIDPortAddressAndState() {
        let r = PortRow(id: "a", pid: 4321, processName: "node",
                        port: tcp(3000, remote: ("10.0.0.7", 443), state: "ESTABLISHED"))
        #expect(r.matches(""))
        #expect(r.matches("NODE"))           // case-insensitive
        #expect(r.matches("4321"))           // PID
        #expect(r.matches("3000"))           // local port
        #expect(r.matches("10.0.0.7"))       // remote address
        #expect(r.matches("establ"))         // state
        #expect(r.matches("tcp"))            // protocol
        #expect(!r.matches("safari"))
        #expect(!r.matches("8080"))
    }

    // MARK: - Filter

    @Test func filterSplitsListeningFromConnected() {
        let rows = [row(1, "a", tcp(3000, state: "LISTEN")),
                    row(2, "b", tcp(52000, remote: ("1.2.3.4", 443), state: "ESTABLISHED")),
                    row(3, "c", udp(5353)),
                    row(4, "d", udp(60000, remote: ("8.8.8.8", 53))),
                    row(5, "e", tcp(52001, state: "CLOSED"))]   // neither listening nor connected
        #expect(PortRow.visible(rows, filter: .all, searchText: "").map(\.pid) == [1, 2, 3, 4, 5])
        #expect(PortRow.visible(rows, filter: .listening, searchText: "").map(\.pid) == [1, 3])
        #expect(PortRow.visible(rows, filter: .connected, searchText: "").map(\.pid) == [2, 4])
        #expect(PortRow.visible(rows, filter: .listening, searchText: "5353").map(\.pid) == [3])
    }
}

/// Against the real kernel: a socket this test opens must show up, under this process.
struct PortsSamplerIntegrationTests {
    @Test func findsAListenerThisProcessOpened() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0                                   // any free port
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)

        let clock = ContinuousClock()
        let start = clock.now
        let rows = await PortsSampler().sample()
        let elapsed = clock.now - start

        let ours = rows.first { $0.pid == getpid() && $0.port.localPort == port }
        #expect(ours?.port.protocolName == "TCP")
        #expect(ours?.stateText == "LISTEN")
        #expect(ours?.localText == "127.0.0.1:\(port)")
        // It runs every 2 s while the surface shows; a full pass must stay well under that.
        #expect(elapsed < .milliseconds(500), "one pass took \(elapsed)")
        print("PortsSampler: \(rows.count) sockets in \(elapsed)")
    }
}

@MainActor
struct PortsModelTests {
    final class FakePortsSampler: PortsSampling, @unchecked Sendable {
        var next: [PortRow] = []
        private(set) var calls = 0
        func sample() async -> [PortRow] { calls += 1; return next }
    }

    @Test func refreshPublishesRows() async {
        let sampler = FakePortsSampler()
        sampler.next = [row(1, "node", tcp(3000, state: "LISTEN"))]
        let model = PortsModel(sampler: sampler)
        await model.refreshOnce()
        #expect(model.rows == sampler.next)
    }

    /// The loop runs only while the Ports surface is showing; leaving it must stop sampling.
    @Test func runStopsAfterCancellation() async throws {
        let sampler = FakePortsSampler()
        let model = PortsModel(sampler: sampler, interval: .milliseconds(10))
        let task = Task { await model.run() }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await task.value
        let calls = sampler.calls
        try await Task.sleep(for: .milliseconds(60))
        #expect(calls > 0)
        #expect(sampler.calls == calls)
    }
}
