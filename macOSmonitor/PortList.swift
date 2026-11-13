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

    /// Case-insensitive substring match over everything the table shows.
    func matches(_ searchText: String) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return [processName, String(pid), port.protocolName, localText, remoteText, stateText]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// The rows the table shows for this filter and search.
    static func visible(_ rows: [PortRow], filter: PortFilter, searchText: String) -> [PortRow] {
        rows.filter { row in
            switch filter {
            case .all:       true
            case .listening: row.isListening
            case .connected: row.isConnected
            }
        }
        .filter { $0.matches(searchText) }
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

    private let sampler: any PortsSampling
    private let interval: Duration

    init(sampler: any PortsSampling = PortsSampler(), interval: Duration = .seconds(2)) {
        self.sampler = sampler
        self.interval = interval
    }

    func refreshOnce() async {
        rows = await sampler.sample()
    }

    func run() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(for: interval)
        }
    }
}
