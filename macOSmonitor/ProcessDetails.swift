import Darwin
import Foundation

/// Static-ish detail about one process, shown in the inspector.
struct ProcessDetails: Equatable, Sendable {
    let path: String?
    let parentPID: pid_t
    let startDate: Date
    let threadCount: Int
    let user: String
    let status: String
}

/// Fetches per-process detail. Implemented by `ProcInfo`; behind a protocol so the
/// model can be tested with a fake.
protocol ProcessDetailProviding: Sendable {
    func details(pid: pid_t) -> ProcessDetails?
}

extension ProcInfo: ProcessDetailProviding {
    func details(pid: pid_t) -> ProcessDetails? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        // One call yields BSD info (.pbsd) + task info (.ptinfo). Short return = EPERM/exit.
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { return nil }
        let bsd = info.pbsd
        let task = info.ptinfo

        // PROC_PIDPATHINFO_MAXSIZE isn't Swift-visible; it's 4 * MAXPATHLEN.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil

        return ProcessDetails(
            path: path,
            parentPID: pid_t(bsd.pbi_ppid),
            startDate: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)),
            threadCount: Int(task.pti_threadnum),
            user: Self.username(forUID: bsd.pbi_uid),
            status: Self.statusName(bsd.pbi_status)
        )
    }

    private static func username(forUID uid: uid_t) -> String {
        if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
            return String(cString: name)
        }
        return "uid \(uid)"
    }

    private static func statusName(_ status: UInt32) -> String {
        switch status {
        case 1: return "Idle"
        case 2: return "Running"
        case 3: return "Sleeping"
        case 4: return "Stopped"
        case 5: return "Zombie"
        default: return "Unknown"
        }
    }
}
