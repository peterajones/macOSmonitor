import Darwin
import SystemConfiguration

/// Cumulative byte counters for one network interface, keyed by its BSD name (`en0`).
struct InterfaceCounters: Equatable, Sendable {
    let name: String
    let received: UInt64
    let sent: UInt64
}

/// What sort of port an interface is. The case order is the breakdown's row order.
enum InterfaceKind: Int, Comparable, Sendable {
    case wifi, ethernet, otherHardware, virtual

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A user-visible hardware port ("Wi-Fi", "USB 10/100/1000 LAN") as System Settings names it.
struct HardwarePort: Equatable, Sendable {
    let displayName: String
    let kind: InterfaceKind
}

/// Network reads, isolated behind a protocol so the sampler can use a fake.
protocol NetworkStatsProviding: Sendable {
    /// Cumulative counters for every non-loopback interface; nil on failure.
    func interfaceCounters() -> [InterfaceCounters]?
    /// Hardware ports keyed by BSD name. Interfaces missing here are virtual (VPN, AirDrop…).
    func hardwarePorts() -> [String: HardwarePort]
}

struct NetworkStats: NetworkStatsProviding {
    /// Reads `NET_RT_IFLIST2`, whose `if_data64` counters are 64-bit. The `if_data` that
    /// `getifaddrs` exposes is 32-bit and wraps every 4 GB — about every 34 s at 1 Gb/s.
    func interfaceCounters() -> [InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        var buffer: [UInt8] = []
        // The table can grow between sizing and reading; retry once with the new size.
        for _ in 0..<2 {
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return nil }
            buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 { break }
            guard errno == ENOMEM else { return nil }
            buffer = []
        }
        guard !buffer.isEmpty else { return nil }

        return buffer.withUnsafeBytes { raw -> [InterfaceCounters] in
            var result: [InterfaceCounters] = []
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length
                else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard message.ifm_flags & IFF_LOOPBACK == 0,
                      let name = Self.name(ofIndex: message.ifm_index)
                else { continue }
                result.append(InterfaceCounters(name: name,
                                                received: message.ifm_data.ifi_ibytes,
                                                sent: message.ifm_data.ifi_obytes))
            }
            return result
        }
    }

    private static func name(ofIndex index: UInt16) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// The ports System Settings lists, by BSD name. Utun, AWDL and the like aren't ports.
    func hardwarePorts() -> [String: HardwarePort] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var ports: [String: HardwarePort] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface)
            let kind: InterfaceKind
            if type == kSCNetworkInterfaceTypeIEEE80211 {
                kind = .wifi
            } else if type == kSCNetworkInterfaceTypeEthernet {
                kind = .ethernet
            } else {
                kind = .otherHardware
            }
            ports[bsdName] = HardwarePort(displayName: displayName, kind: kind)
        }
        return ports
    }
}
