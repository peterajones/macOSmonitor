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

extension ProcInfo: ProcessPortProviding {
    func ports(pid: pid_t) -> [ProcessPort] {
        // Enumerate the process's file descriptors.
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<proc_fdinfo>.stride

        var result: [ProcessPort] = []
        for i in 0..<count where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size
            else { continue }
            if let port = Self.makePort(info.psi) { result.append(port) }
        }
        return result.sorted {
            ($0.protocolName, $0.localPort) < ($1.protocolName, $1.localPort)
        }
    }

    private static func makePort(_ psi: socket_info) -> ProcessPort? {
        switch psi.soi_kind {
        case Int32(SOCKINFO_TCP):
            let tcp = psi.soi_proto.pri_tcp
            return makeINPort(tcp.tcpsi_ini, protocolName: "TCP",
                              state: tcpStateName(tcp.tcpsi_state))
        case Int32(SOCKINFO_IN):
            return makeINPort(psi.soi_proto.pri_in, protocolName: "UDP", state: nil)
        default:
            return nil
        }
    }

    private static func makeINPort(_ ini: in_sockinfo, protocolName: String,
                                   state: String?) -> ProcessPort? {
        let isV6 = (Int32(ini.insi_vflag) & INI_IPV6) != 0
        // Extract the concrete in_addr / in6_addr inline — never name the anonymous
        // address union type (its Swift-synthesized name is unstable).
        let localText = isV6 ? ipv6(ini.insi_laddr.ina_6)
                             : ipv4(ini.insi_laddr.ina_46.i46a_addr4)
        guard let local = localText.map(wildcarded) else { return nil }

        let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
        let foreignPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))

        var remoteAddress: String? = nil
        var remotePort: UInt16? = nil
        if foreignPort != 0 {
            let remoteText = isV6 ? ipv6(ini.insi_faddr.ina_6)
                                  : ipv4(ini.insi_faddr.ina_46.i46a_addr4)
            if let remote = remoteText.map(wildcarded) {
                remoteAddress = remote
                remotePort = foreignPort   // set the pair together, or leave both nil
            }
        }
        return ProcessPort(protocolName: protocolName, localAddress: local, localPort: localPort,
                           remoteAddress: remoteAddress, remotePort: remotePort, state: state)
    }

    private static func ipv4(_ addr: in_addr) -> String? {
        var a = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &a, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func ipv6(_ addr: in6_addr) -> String? {
        var a = addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &a, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Wildcard (0.0.0.0 / ::) renders as "*".
    private static func wildcarded(_ text: String) -> String {
        (text == "0.0.0.0" || text == "::") ? "*" : text
    }

    private static func tcpStateName(_ state: Int32) -> String {
        switch state {
        case 0: return "CLOSED"
        case 1: return "LISTEN"
        case 2: return "SYN_SENT"
        case 3: return "SYN_RECEIVED"
        case 4: return "ESTABLISHED"
        case 5: return "CLOSE_WAIT"
        case 6: return "FIN_WAIT_1"
        case 7: return "CLOSING"
        case 8: return "LAST_ACK"
        case 9: return "FIN_WAIT_2"
        case 10: return "TIME_WAIT"
        default: return "UNKNOWN"
        }
    }
}
