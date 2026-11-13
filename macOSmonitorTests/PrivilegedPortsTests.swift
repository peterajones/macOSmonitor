import Testing
import Foundation
import Darwin
@testable import macOSmonitor

/// Answers `allPorts` with a fixed table; nil stands for "helper not available".
final class FakePortsHelper: PrivilegedProcessAccess, @unchecked Sendable {
    var ports: [pid_t: [ProcessPort]]?
    private(set) var askedForPorts = 0
    func taskSamples(pids: [pid_t]) async -> [pid_t: ProcTaskSample] { [:] }
    func sendSignal(_ signal: Int32, to pid: pid_t) -> Int32? { nil }
    func inspect(pid: pid_t) async -> PrivilegedInspection? { nil }
    func allPorts() async -> [pid_t: [ProcessPort]]? {
        askedForPorts += 1
        return ports
    }
}

private let mdns = ProcessPort(protocolName: "UDP", localAddress: "*", localPort: 5353,
                               remoteAddress: nil, remotePort: nil, state: nil)
private let node = ProcessPort(protocolName: "TCP", localAddress: "127.0.0.1", localPort: 3000,
                               remoteAddress: nil, remotePort: nil, state: "LISTEN")
private let stale = ProcessPort(protocolName: "TCP", localAddress: "127.0.0.1", localPort: 4000,
                                remoteAddress: nil, remotePort: nil, state: "LISTEN")

struct PrivilegedPortsTests {
    private func procs() -> FakeProcInfo {
        let procs = FakeProcInfo()
        procs.pids = [20, 42]
        procs.names = [20: "mDNSResponder", 42: "node"]
        return procs
    }

    @Test func deniedProcessesGetTheirSocketsFromTheHelper() async {
        let local = FakePortsByPID()
        local.ports = [42: [node]]                         // 20 (root) is withheld from us
        let helper = FakePortsHelper()
        // The helper's read of 42 is a moment older than ours; ours wins. 999 has exited
        // since the helper looked: it isn't in our listing, so it gets no row.
        helper.ports = [20: [mdns], 42: [stale], 999: [node]]
        let rows = await PortsSampler(procInfo: procs(), ports: local, privileged: helper).sample()
        #expect(rows.map(\.pid) == [42, 20])               // 3000 LISTEN, then 5353 UDP
        #expect(rows.map(\.processName) == ["node", "mDNSResponder"])
        #expect(rows.map(\.port) == [node, mdns])
        #expect(helper.askedForPorts == 1)
    }

    @Test func withoutTheHelperOnlyReadableProcessesAreListed() async {
        let local = FakePortsByPID()
        local.ports = [42: [node]]
        let helper = FakePortsHelper()                     // ports == nil: not installed / old version
        let rows = await PortsSampler(procInfo: procs(), ports: local, privileged: helper).sample()
        #expect(rows.map(\.pid) == [42])
        let none = await PortsSampler(procInfo: procs(), ports: local).sample()
        #expect(none.map(\.pid) == [42])
    }

    /// A process neither we nor the helper can read (or one with no sockets) adds no row, and an
    /// empty answer from the helper is not a failure: our own sockets still list.
    @Test func aProcessWithSocketsFromNeitherSourceAddsNoRow() async {
        let local = FakePortsByPID()
        local.ports = [42: [node]]
        let helper = FakePortsHelper()
        helper.ports = [:]
        let rows = await PortsSampler(procInfo: procs(), ports: local, privileged: helper).sample()
        #expect(rows.map(\.pid) == [42])
        #expect(helper.askedForPorts == 1)
    }

    @Test func portsRoundTripThroughTheWireFormat() throws {
        let sent: [pid_t: [ProcessPort]] = [20: [mdns], 42: [node, stale]]
        let decoded = try #require(HelperWire.decodePorts(HelperWire.encodePorts(sent)))
        #expect(decoded == sent)
        #expect(HelperWire.decodePorts(Data("junk".utf8)) == nil)
    }
}
