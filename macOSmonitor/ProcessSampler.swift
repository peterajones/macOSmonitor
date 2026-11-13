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
    private let gpu: any ProcessGPUUsageProviding
    /// The root helper, asked for the processes the kernel won't let us read. Nil (the
    /// default) never asks: tests built on fake PIDs must not reach a real installed helper.
    private let privileged: (any PrivilegedProcessAccess)?
    private var previousGPU: [pid_t: UInt64]?
    private let now: @Sendable () -> UInt64
    private var previousCPU: [pid_t: UInt64] = [:]   // pid -> cpuTimeNanos last tick
    private var previousEnergy: [pid_t: UInt64] = [:] // pid -> energyNanojoules last tick
    private var lastWallNanos: UInt64?
    /// uid → account name. A handful of uids cover every process, and getpwuid isn't free.
    private var userNames: [uid_t: String] = [:]

    init(source: any ProcInfoProviding = ProcInfo(),
         apps: any RegularAppProviding = RegularApps(),
         gpu: any ProcessGPUUsageProviding = ProcessGPUUsage(),
         privileged: (any PrivilegedProcessAccess)? = nil,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.source = source
        self.apps = apps
        self.gpu = gpu
        self.privileged = privileged
        self.now = now
    }

    func sample() async -> [ProcessInfoRow] {
        // Read what the kernel lets us, then ask the helper (if any) for the rest in one call.
        let pids = source.listPIDs()
        var samples: [pid_t: ProcTaskSample] = [:]
        for pid in pids { samples[pid] = source.sample(pid: pid) }
        let denied = pids.filter { samples[$0] == nil }
        if let privileged, !denied.isEmpty {
            samples.merge(await privileged.taskSamples(pids: denied)) { mine, _ in mine }
        }

        let wall = now()
        let wallDelta = lastWallNanos.map { wall &- $0 } ?? 0
        let appPIDs = apps.regularAppPIDs()
        let gpuTimes = gpu.gpuTimes()

        var rows: [ProcessInfoRow] = []
        var currentCPU: [pid_t: UInt64] = [:]
        var currentEnergy: [pid_t: UInt64] = [:]

        for pid in pids {
            let name = source.name(pid: pid)
            let uid = source.owner(pid: pid)
            let user = uid.map(userName)
            let path = source.path(pid: pid)
            guard let s = samples[pid] else {
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
            var row = ProcessInfoRow(pid: pid, name: name,
                                     cpuPercent: cpuPercent, memoryBytes: s.residentBytes,
                                     cpuTimeNanos: s.cpuTimeNanos,
                                     isApplication: appPIDs.contains(pid), uid: uid,
                                     user: user, path: path)
            // nJ per ns is watts. A counter that went backwards is a reused PID: no reading.
            if let energy = s.energyNanojoules {
                currentEnergy[pid] = energy
                if let before = previousEnergy[pid], energy >= before, wallDelta > 0 {
                    row.powerWatts = Double(energy - before) / Double(wallDelta)
                }
            }
            rows.append(row)
        }

        // GPU columns: a process's GPU time this tick, and its share of the interval. A counter
        // that went backwards (a client closed, so a summed total dropped) reads 0, not a trap.
        if let gpuTimes {
            for index in rows.indices {
                let pid = rows[index].pid
                let time = gpuTimes[pid] ?? 0
                rows[index].gpuTimeNanos = time
                if let previous = previousGPU, wallDelta > 0 {
                    let before = previous[pid] ?? 0
                    let delta = time >= before ? time - before : 0
                    rows[index].gpuPercent = min(100.0 * Double(delta) / Double(wallDelta), 100)
                }
            }
        }
        previousGPU = gpuTimes

        previousCPU = currentCPU
        previousEnergy = currentEnergy
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
