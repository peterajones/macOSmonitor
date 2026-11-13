import Foundation
import Observation

/// One open socket in the Ports table: which process holds it, and the socket itself.
struct PortRow: Identifiable, Hashable, Sendable {
    /// Unique within one sample, even for identical sockets (SO_REUSEPORT allows a process to
    /// bind the same port twice); a Table with duplicate IDs misdraws rows.
    let id: String
    let pid: pid_t
    let processName: String
    let port: ProcessPort

    /// "127.0.0.1:3000", "*:5353".
    var localText: String { "\(port.localAddress):\(port.localPort)" }
    /// "1.2.3.4:443", or "—" when there is no peer.
    var remoteText: String {
        guard let address = port.remoteAddress, let remotePort = port.remotePort else { return "—" }
        return "\(address):\(remotePort)"
    }
    /// The TCP state, or "—" for UDP.
    var stateText: String { port.state ?? "—" }

    /// Waiting for connections: a TCP listener, or a UDP socket with no fixed peer.
    var isListening: Bool {
        port.state == "LISTEN" || (port.protocolName == "UDP" && port.remoteAddress == nil)
    }
    /// Talking to a peer.
    var isConnected: Bool { port.remoteAddress != nil }

    // Sort keys for the table's columns.
    var localPortKey: Int { Int(port.localPort) }
    var protocolKey: String { port.protocolName }

    /// Case-insensitive substring match over everything the table shows, including the
    /// remote host's name when it has been resolved.
    func matches(_ searchText: String, hostName: String? = nil) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return [processName, String(pid), port.protocolName, localText, remoteText, stateText, hostName ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// The rows the table shows for this filter and search; `hostNames` maps remote
    /// addresses to their reverse-DNS names.
    static func visible(_ rows: [PortRow], filter: PortFilter, searchText: String,
                        hostNames: [String: String] = [:]) -> [PortRow] {
        rows.filter { row in
            switch filter {
            case .all:       true
            case .listening: row.isListening
            case .connected: row.isConnected
            }
        }
        .filter { row in row.matches(searchText, hostName: row.port.remoteAddress.flatMap { hostNames[$0] }) }
    }
}

/// The Ports surface's Show picker.
enum PortFilter: String, CaseIterable, Identifiable, Sendable {
    case all, listening, connected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:       "All"
        case .listening: "Listening"
        case .connected: "Connected"
        }
    }
}

protocol PortsSampling: Sendable {
    func sample() async -> [PortRow]
}

/// Lists every process's open TCP/UDP sockets. Processes we may not read (other users',
/// root's) contribute none: their descriptors need the privileged helper.
actor PortsSampler: PortsSampling {
    private let procInfo: any ProcInfoProviding
    private let ports: any ProcessPortProviding

    init(procInfo: any ProcInfoProviding = ProcInfo(), ports: any ProcessPortProviding = ProcInfo()) {
        self.procInfo = procInfo
        self.ports = ports
    }

    /// Listening sockets first (the "what's on port 3000?" question), each group by local
    /// port, then PID.
    func sample() -> [PortRow] {
        var rows: [PortRow] = []
        var seen: [String: Int] = [:]
        for pid in procInfo.listPIDs() {
            let sockets = ports.ports(pid: pid)
            guard !sockets.isEmpty else { continue }
            let name = procInfo.name(pid: pid)
            for socket in sockets {
                let base = "\(pid)|\(socket.displayText)"
                let occurrence = seen[base, default: 0]
                seen[base] = occurrence + 1
                rows.append(PortRow(id: occurrence == 0 ? base : "\(base)#\(occurrence)",
                                    pid: pid, processName: name, port: socket))
            }
        }
        return rows.sorted {
            ($0.isListening ? 0 : 1, $0.port.localPort, $0.pid) < ($1.isListening ? 0 : 1, $1.port.localPort, $1.pid)
        }
    }
}

/// Every open socket, refreshed while the Ports surface is showing. Owned per window by
/// `ContentView` so the last sample is there on return; the loop runs from the Ports view's
/// `.task`, so it stops when you navigate away (reading every process's descriptors isn't
/// free, and nothing else needs it).
@MainActor
@Observable
final class PortsModel {
    private(set) var rows: [PortRow] = []
    /// Reverse-DNS names of the rows' remote addresses, where they have one.
    private(set) var hostNames: [String: String] = [:]

    private let sampler: any PortsSampling
    private let dns: ReverseDNS
    private let interval: Duration

    init(sampler: any PortsSampling = PortsSampler(), dns: ReverseDNS = ReverseDNS(),
         interval: Duration = .seconds(2)) {
        self.sampler = sampler
        self.dns = dns
        self.interval = interval
    }

    /// One sample and its host names, in order. `run()` doesn't use this: there the names
    /// are looked up beside the loop, so the table never waits on DNS.
    func refreshOnce() async {
        rows = await sampler.sample()
        await resolveHostNames()
    }

    /// Looks up the current rows' remote addresses (new ones only: answers are cached).
    func resolveHostNames() async {
        hostNames = await dns.resolve(Set(rows.compactMap(\.port.remoteAddress)))
    }

    /// The remote host's name for `row`, or nil when unresolved or there is no peer.
    func hostName(for row: PortRow) -> String? {
        row.port.remoteAddress.flatMap { hostNames[$0] }
    }

    func run() async {
        // A lookup can block for seconds (a resolver timing out), so names resolve in a task
        // of their own, one batch at a time, and fill in on a later tick.
        var lookups: Task<Void, Never>?
        defer { lookups?.cancel() }
        while !Task.isCancelled {
            rows = await sampler.sample()
            if !isResolving {
                isResolving = true
                lookups = Task { [weak self] in
                    await self?.resolveHostNames()
                    self?.isResolving = false
                }
            }
            try? await Task.sleep(for: interval)
        }
    }

    @ObservationIgnored private var isResolving = false
}
