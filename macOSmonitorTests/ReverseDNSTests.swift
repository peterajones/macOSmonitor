import Testing
import Foundation
@testable import macOSmonitor

/// Counts lookups and answers from a table; `nil` in the table means "no PTR record".
final class FakeHostLookup: HostLookup, @unchecked Sendable {
    var answers: [String: String?] = [:]
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    func lookUp(_ address: String) async -> String? {
        lock.withLock { _calls.append(address) }
        return answers[address] ?? nil
    }
}

struct ReverseDNSTests {
    @Test func resolvesOnceAndCachesAnswersAndMisses() async {
        let lookup = FakeHostLookup()
        lookup.answers = ["140.82.112.3": "lb-140-82-112-3-iad.github.com", "10.0.0.9": nil]
        let dns = ReverseDNS(lookup: lookup)

        let first = await dns.resolve(["140.82.112.3", "10.0.0.9"])
        #expect(first == ["140.82.112.3": "lb-140-82-112-3-iad.github.com"])

        let again = await dns.resolve(["140.82.112.3", "10.0.0.9"])
        #expect(again == first)
        // A miss is cached too: an address with no PTR record isn't asked about every tick.
        #expect(lookup.calls.sorted() == ["10.0.0.9", "140.82.112.3"])
    }

    @Test func wildcardsAreNeverLookedUp() async {
        let lookup = FakeHostLookup()
        let dns = ReverseDNS(lookup: lookup)
        _ = await dns.resolve(["*"])
        #expect(lookup.calls.isEmpty)
    }

    /// Against the real resolver: loopback has a name in /etc/hosts on every Mac.
    @Test func realLookupNamesLoopback() async {
        let name = await SystemHostLookup().lookUp("127.0.0.1")
        #expect(name == "localhost")
    }
}

@MainActor
struct PortsModelHostNameTests {
    final class FixedSampler: PortsSampling, @unchecked Sendable {
        var rows: [PortRow] = []
        func sample() async -> [PortRow] { rows }
    }

    @Test func refreshResolvesRemoteAddresses() async {
        let sampler = FixedSampler()
        sampler.rows = [PortRow(id: "a", pid: 1, processName: "node",
                                port: ProcessPort(protocolName: "TCP", localAddress: "127.0.0.1", localPort: 52000,
                                                  remoteAddress: "140.82.112.3", remotePort: 443, state: "ESTABLISHED")),
                        PortRow(id: "b", pid: 1, processName: "node",
                                port: ProcessPort(protocolName: "TCP", localAddress: "*", localPort: 3000,
                                                  remoteAddress: nil, remotePort: nil, state: "LISTEN"))]
        let lookup = FakeHostLookup()
        lookup.answers = ["140.82.112.3": "github.com"]
        let model = PortsModel(sampler: sampler, dns: ReverseDNS(lookup: lookup))

        await model.refreshOnce()
        #expect(model.hostNames == ["140.82.112.3": "github.com"])
        #expect(model.hostName(for: model.rows[0]) == "github.com")
        #expect(model.hostName(for: model.rows[1]) == nil)
    }

    /// A resolver timing out must not freeze the table: sampling carries on meanwhile.
    @Test func slowLookupsDontHoldUpSampling() async throws {
        final class CountingSampler: PortsSampling, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            var calls: Int { lock.withLock { _calls } }
            func sample() async -> [PortRow] {
                lock.withLock { _calls += 1 }
                return [PortRow(id: "a", pid: 1, processName: "node",
                                port: ProcessPort(protocolName: "TCP", localAddress: "127.0.0.1", localPort: 52000,
                                                  remoteAddress: "192.0.2.1", remotePort: 443, state: "ESTABLISHED"))]
            }
        }
        struct HangingLookup: HostLookup {
            func lookUp(_ address: String) async -> String? {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
        }
        let sampler = CountingSampler()
        let model = PortsModel(sampler: sampler, dns: ReverseDNS(lookup: HangingLookup()), interval: .milliseconds(10))
        let task = Task { await model.run() }
        // Wait for 5 samples rather than counting what a fixed window held: under a loaded
        // test run 300 ms sometimes fitted only 4. The deadline stays well inside the 5 s
        // hang, so a loop that waited on the lookup still fails, with 1 sample.
        let deadline = ContinuousClock.now + .seconds(2)
        while sampler.calls < 5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await task.value
        #expect(sampler.calls >= 5, "sampled \(sampler.calls) times while a lookup hung")
    }

    @Test func searchMatchesTheHostName() {
        let row = PortRow(id: "a", pid: 1, processName: "node",
                          port: ProcessPort(protocolName: "TCP", localAddress: "127.0.0.1", localPort: 52000,
                                            remoteAddress: "140.82.112.3", remotePort: 443, state: "ESTABLISHED"))
        #expect(PortRow.visible([row], filter: .all, searchText: "github",
                                hostNames: ["140.82.112.3": "github.com"]).count == 1)
        #expect(PortRow.visible([row], filter: .all, searchText: "github", hostNames: [:]).isEmpty)
    }
}
