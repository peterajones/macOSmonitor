import Foundation

/// A process's network traffic: the sum over its open sockets, from NetworkStatistics.
/// Bytes moved over sockets that have since closed aren't included, so this is "what its open
/// connections have carried", not "since launch".
struct ProcessNetworkUsage: Equatable, Sendable {
    let pid: pid_t
    /// Totals over the process's open sockets.
    let counts: SocketCounts
    let socketCount: Int
    /// Each socket's counts by `SocketTraffic.key`, for rates (identical sockets summed).
    private let bySocket: [String: SocketCounts]

    init(pid: pid_t, readings: [SocketTraffic]) {
        let mine = readings.filter { $0.pid == pid }
        var bySocket: [String: SocketCounts] = [:]
        for socket in mine {
            let old = bySocket[socket.key]
            bySocket[socket.key] = SocketCounts(rxBytes: (old?.rxBytes ?? 0) &+ socket.counts.rxBytes,
                                                txBytes: (old?.txBytes ?? 0) &+ socket.counts.txBytes)
        }
        self.pid = pid
        self.bySocket = bySocket
        self.socketCount = mine.count
        self.counts = SocketCounts(rxBytes: bySocket.values.reduce(0) { $0 &+ $1.rxBytes },
                                   txBytes: bySocket.values.reduce(0) { $0 &+ $1.txBytes })
    }

    /// Bytes per second since `earlier`, counting only sockets open on both readings: one that
    /// closed would make the total drop, and one that opened would add its whole history at
    /// once. A socket whose counter went backwards (closed and reopened on the same ports) is
    /// left out too. Nil when `earlier` is another process or no time has passed.
    func rates(since earlier: ProcessNetworkUsage, seconds: Double) -> SocketRates? {
        guard earlier.pid == pid, seconds > 0 else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (key, now) in bySocket {
            guard let before = earlier.bySocket[key],
                  now.rxBytes >= before.rxBytes, now.txBytes >= before.txBytes else { continue }
            rx += now.rxBytes - before.rxBytes
            tx += now.txBytes - before.txBytes
        }
        return SocketRates(rxPerSec: Double(rx) / seconds, txPerSec: Double(tx) / seconds)
    }
}
