import Darwin

/// One open network socket held by a process.
struct ProcessPort: Equatable, Sendable {
    let protocolName: String    // "TCP" / "UDP"
    let localAddress: String    // "127.0.0.1", "::1", or "*" for a wildcard bind
    let localPort: UInt16
    let remoteAddress: String?  // nil when listening / unconnected
    let remotePort: UInt16?
    let state: String?          // TCP state name; nil for UDP

    /// e.g. "TCP  *:443 (LISTEN)" or "TCP  127.0.0.1:8080 → 1.2.3.4:443 (ESTABLISHED)".
    var displayText: String {
        var text = "\(protocolName)  \(localAddress):\(localPort)"
        if let remoteAddress, let remotePort { text += " → \(remoteAddress):\(remotePort)" }
        if let state { text += " (\(state))" }
        return text
    }
}

/// Enumerates a process's open network sockets. Implemented by `ProcInfo`; behind a protocol
/// so the model can be tested with a fake.
protocol ProcessPortProviding: Sendable {
    func ports(pid: pid_t) -> [ProcessPort]
}
