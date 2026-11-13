import Foundation
import Darwin

/// An address and port, written the way the socket table writes them ("*" for a wildcard).
struct SocketEndpoint: Hashable, Sendable {
    let address: String
    let port: UInt16

    init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }

    /// From raw `sockaddr_in` / `sockaddr_in6` bytes; nil for anything else.
    init?(sockaddr data: Data) {
        guard data.count >= 2 else { return nil }
        let family = Int32(data[data.startIndex + 1])
        let parsed: (String?, UInt16)? = data.withUnsafeBytes { raw in
            switch family {
            case AF_INET where raw.count >= MemoryLayout<sockaddr_in>.size:
                let sa = raw.loadUnaligned(as: sockaddr_in.self)
                return (ProcInfo.ipv4(sa.sin_addr), UInt16(bigEndian: sa.sin_port))
            case AF_INET6 where raw.count >= MemoryLayout<sockaddr_in6>.size:
                let sa = raw.loadUnaligned(as: sockaddr_in6.self)
                return (ProcInfo.ipv6(sa.sin6_addr), UInt16(bigEndian: sa.sin6_port))
            default:
                return nil
            }
        }
        guard let parsed, let address = parsed.0 else { return nil }
        self.address = ProcInfo.wildcarded(address)
        self.port = parsed.1
    }
}

/// Bytes a socket has moved since it opened.
struct SocketCounts: Hashable, Sendable {
    let rxBytes: UInt64
    let txBytes: UInt64
}

/// Bytes per second over the last interval.
struct SocketRates: Hashable, Sendable {
    let rxPerSec: Double
    let txPerSec: Double
}

/// One socket's traffic as NetworkStatistics reports it.
struct SocketTraffic: Equatable, Sendable {
    let pid: pid_t
    let protocolName: String
    let local: SocketEndpoint
    let remote: SocketEndpoint?
    let counts: SocketCounts

    /// Matches `PortRow.trafficKey` for the same socket.
    var key: String {
        SocketTrafficKey.make(pid: pid, protocolName: protocolName, localPort: local.port,
                              remoteAddress: remote?.address, remotePort: remote?.port)
    }
}

/// The two APIs describe a socket slightly differently, so matching uses only what both agree
/// on: process, protocol, local port, and the peer. An unconnected peer (port 0) counts as no
/// peer, and an IPv4-mapped IPv6 peer as its plain IPv4 form.
enum SocketTrafficKey {
    static func make(pid: pid_t, protocolName: String, localPort: UInt16,
                     remoteAddress: String?, remotePort: UInt16?) -> String {
        var peer = "-"
        if let remoteAddress, let remotePort, remotePort != 0 {
            let plain = remoteAddress.hasPrefix("::ffff:") && remoteAddress.contains(".")
                ? String(remoteAddress.dropFirst(7)) : remoteAddress
            peer = "\(plain):\(remotePort)"
        }
        return "\(pid)|\(protocolName)|\(localPort)|\(peer)"
    }
}

extension PortRow {
    var trafficKey: String {
        SocketTrafficKey.make(pid: pid, protocolName: port.protocolName, localPort: port.localPort,
                              remoteAddress: port.remoteAddress, remotePort: port.remotePort)
    }

    /// "18.5 MB  ·  2.1 KB/s", or "—" when there's no reading.
    var receivedText: String { Self.text(counts?.rxBytes, rates?.rxPerSec) }
    var sentText: String { Self.text(counts?.txBytes, rates?.txPerSec) }

    // Sort keys: sockets without a reading sort below zero.
    var receivedSortKey: Int64 { counts.map { Int64(clamping: $0.rxBytes) } ?? -1 }
    var sentSortKey: Int64 { counts.map { Int64(clamping: $0.txBytes) } ?? -1 }

    private static func text(_ bytes: UInt64?, _ perSec: Double?) -> String {
        guard let bytes else { return "—" }
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
        return "\(total)  ·  \(perSec.map(SystemVitals.rate) ?? "—")"
    }
}

/// Reads per-socket byte counts; behind a protocol so the model can be tested with a fake.
protocol SocketTrafficProviding: Sendable {
    /// Nil when the private framework is unavailable (a macOS update removed or changed it).
    func read() async -> [SocketTraffic]?
}

/// Per-socket byte counts from NetworkStatistics, the private framework behind `nettop`. Loaded
/// by name at runtime, so a missing function means "no reading", never a failed launch. No
/// root needed; like `proc_pidfdinfo`, it reports only this user's processes.
///
/// Each source reports two dictionaries, and neither is enough alone (found by probing):
/// - its **description** names the process and addresses, but its byte counts are a snapshot
///   that lags a query behind;
/// - its **counts** are live, but in practice carry no addresses.
/// So identities come from descriptions (asked for only when new sockets have appeared) and
/// bytes from counts, joined by source.
///
/// The framework calls back on `queue`, and every piece of mutable state here is touched only
/// on that queue; hence `@unchecked Sendable`.
final class NStatSocketTraffic: SocketTrafficProviding, @unchecked Sendable {
    private typealias SourceHandler = @convention(block) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    private typealias DictionaryHandler = @convention(block) (CFDictionary?) -> Void
    private typealias VoidHandler = @convention(block) () -> Void
    // The framework keeps every block it is given (and calls the source handler for each new
    // socket), so each block parameter must be @escaping: a non-escaping one traps at run time
    // with "non-escaping closure has escaped".
    private typealias CreateFn = @convention(c) (CFAllocator?, DispatchQueue, @escaping SourceHandler) -> OpaquePointer?
    private typealias ManagerFn = @convention(c) (OpaquePointer) -> Void
    private typealias SetDictionaryFn = @convention(c) (OpaquePointer, @escaping DictionaryHandler) -> Void
    private typealias SetVoidFn = @convention(c) (OpaquePointer, @escaping VoidHandler) -> Void
    private typealias QueryFn = @convention(c) (OpaquePointer, @escaping VoidHandler) -> Void

    private struct Functions {
        let create: CreateFn, addTCP: ManagerFn, addUDP: ManagerFn
        let setDescription: SetDictionaryFn, setCounts: SetDictionaryFn, setRemoved: SetVoidFn
        let queryDescriptions: QueryFn, queryCounts: QueryFn
    }

    /// Who a socket belongs to and where it points; fixed for the socket's life.
    struct Identity: Equatable, Sendable {
        let pid: pid_t
        let protocolName: String
        let local: SocketEndpoint
        let remote: SocketEndpoint?
    }

    private let queue = DispatchQueue(label: "macOSmonitor.socket-traffic")
    private var manager: OpaquePointer?
    private var didSetUp = false
    private var identities: [UInt: Identity] = [:]
    private var counts: [UInt: SocketCounts] = [:]
    /// Set when a socket appears, so the next read asks for descriptions.
    private var hasNewSources = false

    func read() async -> [SocketTraffic]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let manager = setUpIfNeeded(), let functions = Self.functions else {
                    continuation.resume(returning: nil)
                    return
                }
                // Each completion runs on `queue` after every source has called back.
                let collect: VoidHandler = { [self] in
                    functions.queryCounts(manager) { [self] in continuation.resume(returning: joined()) }
                }
                if hasNewSources {
                    hasNewSources = false
                    functions.queryDescriptions(manager, collect)
                } else {
                    collect()
                }
            }
        }
    }

    /// On `queue`.
    private func joined() -> [SocketTraffic] {
        identities.compactMap { id, identity in
            counts[id].map { SocketTraffic(pid: identity.pid, protocolName: identity.protocolName,
                                           local: identity.local, remote: identity.remote, counts: $0) }
        }
    }

    /// On `queue`.
    private func setUpIfNeeded() -> OpaquePointer? {
        if didSetUp { return manager }
        didSetUp = true
        guard let functions = Self.functions else { return nil }
        manager = functions.create(kCFAllocatorDefault, queue) { [weak self] source, _ in
            guard let self, let source else { return }
            let id = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(source)))
            hasNewSources = true
            functions.setDescription(source) { [weak self] description in
                guard let description, let identity = Self.identity(from: description as NSDictionary) else { return }
                self?.identities[id] = identity
            }
            functions.setCounts(source) { [weak self] counts in
                guard let counts, let parsed = Self.counts(from: counts as NSDictionary) else { return }
                self?.counts[id] = parsed
            }
            functions.setRemoved(source) { [weak self] in
                self?.identities[id] = nil
                self?.counts[id] = nil
            }
        }
        if let manager {
            functions.addTCP(manager)
            functions.addUDP(manager)
        }
        return manager
    }

    static func identity(from d: NSDictionary) -> Identity? {
        guard let pid = (d["processID"] as? NSNumber)?.int32Value,
              let provider = d["provider"] as? String, provider == "TCP" || provider == "UDP",
              let localData = d["localAddress"] as? Data,
              let local = SocketEndpoint(sockaddr: localData) else { return nil }
        return Identity(pid: pid, protocolName: provider, local: local,
                        remote: (d["remoteAddress"] as? Data).flatMap(SocketEndpoint.init(sockaddr:)))
    }

    static func counts(from d: NSDictionary) -> SocketCounts? {
        guard let rx = (d["rxBytes"] as? NSNumber)?.uint64Value,
              let tx = (d["txBytes"] as? NSNumber)?.uint64Value else { return nil }
        return SocketCounts(rxBytes: rx, txBytes: tx)
    }

    private static let functions: Functions? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics",
                                  RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = symbol("NStatManagerCreate", as: CreateFn.self),
              let addTCP = symbol("NStatManagerAddAllTCP", as: ManagerFn.self),
              let addUDP = symbol("NStatManagerAddAllUDP", as: ManagerFn.self),
              let setDescription = symbol("NStatSourceSetDescriptionBlock", as: SetDictionaryFn.self),
              let setCounts = symbol("NStatSourceSetCountsBlock", as: SetDictionaryFn.self),
              let setRemoved = symbol("NStatSourceSetRemovedBlock", as: SetVoidFn.self),
              let queryDescriptions = symbol("NStatManagerQueryAllSourcesDescriptions", as: QueryFn.self),
              let queryCounts = symbol("NStatManagerQueryAllSources", as: QueryFn.self)
        else { return nil }
        return Functions(create: create, addTCP: addTCP, addUDP: addUDP, setDescription: setDescription,
                         setCounts: setCounts, setRemoved: setRemoved,
                         queryDescriptions: queryDescriptions, queryCounts: queryCounts)
    }()
}
