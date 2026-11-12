import Darwin
import Foundation

protocol ProcessSampling: Sendable {
    func sample() async -> [ProcessInfoRow]
}

/// Enumerates processes and computes CPU% by diffing each process's cumulative
/// CPU time against the previous tick. Runs off the main thread (plain actor).
actor ProcessSampler: ProcessSampling {
    private let source: any ProcInfoProviding
    private let apps: any RegularAppProviding
    private let now: @Sendable () -> UInt64
    private var previousCPU: [pid_t: UInt64] = [:]   // pid -> cpuTimeNanos last tick
    private var lastWallNanos: UInt64?
    /// uid → account name. A handful of uids cover every process, and getpwuid isn't free.
    private var userNames: [uid_t: String] = [:]

    init(source: any ProcInfoProviding = ProcInfo(),
         apps: any RegularAppProviding = RegularApps(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.source = source
        self.apps = apps
        self.now = now
    }

    func sample() -> [ProcessInfoRow] {
        let wall = now()
        let wallDelta = lastWallNanos.map { wall &- $0 } ?? 0
        let appPIDs = apps.regularAppPIDs()

        var rows: [ProcessInfoRow] = []
        var currentCPU: [pid_t: UInt64] = [:]

        for pid in source.listPIDs() {
            let name = source.name(pid: pid)
            let uid = source.owner(pid: pid)
            let user = uid.map(userName)
            let path = source.path(pid: pid)
            guard let s = source.sample(pid: pid) else {
                // Denied (EPERM) or vanished: name + pid only (Decision A).
                rows.append(ProcessInfoRow(pid: pid, name: name, cpuPercent: nil, memoryBytes: nil,
                                           isApplication: appPIDs.contains(pid), uid: uid,
                                           user: user, path: path))
                continue
            }
            currentCPU[pid] = s.cpuTimeNanos

            var cpuPercent: Double? = nil
            if let prev = previousCPU[pid], wallDelta > 0 {
                let cpuDelta = s.cpuTimeNanos >= prev ? s.cpuTimeNanos - prev : 0
                cpuPercent = 100.0 * Double(cpuDelta) / Double(wallDelta)
            }
            rows.append(ProcessInfoRow(pid: pid, name: name,
                                       cpuPercent: cpuPercent, memoryBytes: s.residentBytes,
                                       cpuTimeNanos: s.cpuTimeNanos,
                                       isApplication: appPIDs.contains(pid), uid: uid,
                                           user: user, path: path))
        }

        previousCPU = currentCPU
        lastWallNanos = wall
        return rows
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).flatMap { $0.pointee.pw_name.map { String(cString: $0) } } ?? String(uid)
        userNames[uid] = name
        return name
    }
}
