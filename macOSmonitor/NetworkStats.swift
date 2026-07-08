import Darwin

/// Cumulative network byte counters, isolated behind a protocol so the sampler can use a fake.
protocol NetworkStatsProviding: Sendable {
    func counters() -> (received: UInt64, sent: UInt64)?
}

struct NetworkStats: NetworkStatsProviding {
    func counters() -> (received: UInt64, sent: UInt64)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer = ifap
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = current.pointee.ifa_data
            else { continue }
            let info = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(info.ifi_ibytes)   // 32-bit counters summed into UInt64
            sent += UInt64(info.ifi_obytes)
        }
        return (received, sent)
    }
}
