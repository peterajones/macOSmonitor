import Testing
@testable import macOSmonitor

struct NetworkStatsTests {
    @Test func interfaceCountersArePresentAndExcludeLoopback() {
        let interfaces = NetworkStats().interfaceCounters() ?? []
        #expect(!interfaces.isEmpty)
        #expect(!interfaces.contains { $0.name.hasPrefix("lo") })
        #expect(!interfaces.contains { $0.name.isEmpty })
        // A real machine has cumulative traffic on at least one non-loopback interface.
        #expect(interfaces.contains { $0.received + $0.sent > 0 })
    }

    @Test func hardwarePortsAreNamedAndExcludeVirtualInterfaces() {
        let ports = NetworkStats().hardwarePorts()
        #expect(!ports.isEmpty)
        #expect(ports.values.allSatisfy { !$0.displayName.isEmpty && $0.kind != .virtual })
        #expect(ports["lo0"] == nil)
        #expect(!ports.keys.contains { $0.hasPrefix("utun") })
    }
}
