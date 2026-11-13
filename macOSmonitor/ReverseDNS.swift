import Foundation

/// One reverse lookup: an IP address's host name, or nil when it has none. Behind a protocol
/// so the cache can be tested without the network.
protocol HostLookup: Sendable {
    func lookUp(_ address: String) async -> String?
}

/// The system resolver (`getnameinfo`, so /etc/hosts and mDNS count, as in `lsof`). The call
/// blocks, sometimes for seconds, so it runs on a Dispatch thread rather than holding a
/// Swift-concurrency thread, whose pool is only as big as the core count.
struct SystemHostLookup: HostLookup {
    func lookUp(_ address: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.blockingLookUp(address))
            }
        }
    }

    private static func blockingLookUp(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST          // parse only: never a forward lookup
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                          &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cBuffer: host)
    }
}

/// Reverse-DNS names for remote addresses, each looked up once per run. Misses are cached
/// too, so an address with no PTR record isn't queried again every tick.
actor ReverseDNS {
    private let lookup: any HostLookup
    private var cache: [String: String?] = [:]

    init(lookup: any HostLookup = SystemHostLookup()) {
        self.lookup = lookup
    }

    /// Names for those of `addresses` that have one, looking up any not seen before
    /// concurrently. "*" (a wildcard bind) is never looked up.
    func resolve(_ addresses: Set<String>) async -> [String: String] {
        let unseen = addresses.filter { $0 != "*" && cache[$0] == nil }
        if !unseen.isEmpty {
            let lookup = lookup
            let found = await withTaskGroup(of: (String, String?).self) { group in
                for address in unseen { group.addTask { (address, await lookup.lookUp(address)) } }
                var found: [(String, String?)] = []
                for await pair in group { found.append(pair) }
                return found
            }
            for (address, name) in found { cache[address] = .some(name) }
        }
        var names: [String: String] = [:]
        for address in addresses {
            if case let .some(.some(name)) = cache[address] { names[address] = name }
        }
        return names
    }
}
