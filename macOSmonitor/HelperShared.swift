import Foundation
import Darwin

// Compiled into BOTH the app and macOSmonitorHelper (target membership ticked for each): the
// two sides of the XPC connection must agree on these names and the message protocol.

enum HelperConstants {
    /// launchd label and Mach service name; also the plist's file name without ".plist".
    static let machServiceName = "ca.peter-jones.macOSmonitor.helper"
    static let plistName = "ca.peter-jones.macOSmonitor.helper.plist"
    /// Bumped when the protocol changes, so the app can tell an out-of-date helper.
    static let protocolVersion = 2   // 2: inspect(pid:)

    /// The only client the helper obeys: this app, signed by Peter's team. Without this, any
    /// process on the Mac could ask a root daemon to kill things.
    ///
    /// A Release helper also refuses debuggable builds: `get-task-allow` lets any process of
    /// the same user attach to the app and inject code, which would then drive the helper.
    /// Debug builds (Xcode runs) carry that entitlement, so a Debug helper must accept it.
    static func clientRequirement(debug: Bool) -> String {
        let base = #"anchor apple generic and identifier "ca.peter-jones.macOSmonitor" and certificate leaf[subject.OU] = "8QQC2WMRHS""#
        return debug ? base : base + #" and !entitlement["com.apple.security.get-task-allow"]"#
    }

    /// The requirement for this build of the helper.
    static var clientRequirement: String {
        #if DEBUG
        clientRequirement(debug: true)
        #else
        clientRequirement(debug: false)
        #endif
    }
    /// The only helper the app talks to: the one it ships, signed by the same team.
    static let helperRequirement =
        #"anchor apple generic and identifier "macOSmonitorHelper" and certificate leaf[subject.OU] = "8QQC2WMRHS""#
}

/// One finished per-process sample. `cpuTimeNanos` is total (user + system) CPU
/// time already converted from Mach ticks to nanoseconds.
struct ProcTaskSample: Sendable {
    let residentBytes: UInt64
    let cpuTimeNanos: UInt64
}

/// The XPC interface. Plain types only (Objective-C bridging); errors travel as errno values.
@objc protocol PrivilegedHelperProtocol {
    func protocolVersion(reply: @escaping (Int) -> Void)
    /// `reply(0)` on success, otherwise an errno (EPERM when the helper refuses, ESRCH when
    /// the process is gone).
    func sendSignal(_ signal: Int32, toPID pid: Int32, reply: @escaping (Int32) -> Void)
    /// Memory and CPU time for `pids`, as `HelperWire.encodeSamples` data.
    func taskSamples(forPIDs pids: [NSNumber], reply: @escaping (Data) -> Void)
    /// Everything the inspector shows for `pid`, as `HelperWire.encodeInspection` data.
    func inspect(pid: Int32, reply: @escaping (Data) -> Void)
}

/// What the inspector shows for one process, read as root by the helper with the same
/// readers the app uses for its own processes. Each part is nil (or empty) when unreadable.
///
/// It never carries an environment: macOS shows a user only their own processes' environments
/// (which hold tokens and keys), and the helper must not widen that. Arguments stay, since
/// `ps` already shows every process's command line to every user. The rule is enforced in both
/// initialisers, so neither a helper build nor a decoded message can get round it.
struct PrivilegedInspection: Equatable, Sendable, Codable {
    let details: ProcessDetails?
    let ports: [ProcessPort]
    let commandLine: ProcessCommandLine?
    let openFiles: [OpenFile]?
    let threads: [ThreadInfo]?
    let usage: ProcessResourceUsage?

    init(details: ProcessDetails?, ports: [ProcessPort], commandLine: ProcessCommandLine?,
         openFiles: [OpenFile]?, threads: [ThreadInfo]?, usage: ProcessResourceUsage?) {
        self.details = details
        self.ports = ports
        self.commandLine = commandLine.map { ProcessCommandLine(arguments: $0.arguments, environment: []) }
        self.openFiles = openFiles
        self.threads = threads
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case details, ports, commandLine, openFiles, threads, usage
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(details: try c.decodeIfPresent(ProcessDetails.self, forKey: .details),
                  ports: try c.decode([ProcessPort].self, forKey: .ports),
                  commandLine: try c.decodeIfPresent(ProcessCommandLine.self, forKey: .commandLine),
                  openFiles: try c.decodeIfPresent([OpenFile].self, forKey: .openFiles),
                  threads: try c.decodeIfPresent([ThreadInfo].self, forKey: .threads),
                  usage: try c.decodeIfPresent(ProcessResourceUsage.self, forKey: .usage))
    }
}

/// What the helper will and won't do, kept apart from the XPC plumbing so it's testable.
enum HelperRules {
    /// The signals the app sends (Quit, Force Quit, Pause, Resume, Hang Up).
    static let allowedSignals: Set<Int32> = [SIGTERM, SIGKILL, SIGSTOP, SIGCONT, SIGHUP]

    /// Whether `uid` is in the admin group (gid 80), asked of Directory Services the way the
    /// system's own authorization checks do (nested groups count). Root always is. The helper
    /// accepts only admins: a standard account must not gain root's power to signal any
    /// process just by opening the app.
    static func isAdmin(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let membership = Membership.functions else { return false }   // fail closed
        var userUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var adminUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var isMember: Int32 = 0
        let ok = withUnsafeMutableBytes(of: &userUUID) { user in
            withUnsafeMutableBytes(of: &adminUUID) { admin in
                membership.uidToUUID(uid, user.baseAddress!) == 0
                    && membership.gidToUUID(80, admin.baseAddress!) == 0
                    && membership.check(user.baseAddress!, admin.baseAddress!, &isMember) == 0
            }
        }
        return ok && isMember == 1
    }

    /// `<membership.h>` is public libSystem API but not in Swift's Darwin module, so its three
    /// functions are looked up by name.
    private enum Membership {
        typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutableRawPointer) -> Int32
        typealias GIDToUUID = @convention(c) (gid_t, UnsafeMutableRawPointer) -> Int32
        typealias Check = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32

        static let functions: (uidToUUID: UIDToUUID, gidToUUID: GIDToUUID, check: Check)? = {
            let handle = dlopen(nil, RTLD_NOW)
            guard let u = dlsym(handle, "mbr_uid_to_uuid"),
                  let g = dlsym(handle, "mbr_gid_to_uuid"),
                  let c = dlsym(handle, "mbr_check_membership") else { return nil }
            return (unsafeBitCast(u, to: UIDToUUID.self), unsafeBitCast(g, to: GIDToUUID.self),
                    unsafeBitCast(c, to: Check.self))
        }()
    }

    /// Nil to go ahead; otherwise the errno to refuse with. Refuses launchd (killing it panics
    /// the Mac), the kernel, kill()'s group/broadcast PIDs (≤ 0), and the helper itself.
    static func refusal(signal: Int32, pid: Int32, helperPID: Int32) -> Int32? {
        guard allowedSignals.contains(signal) else { return EINVAL }
        guard pid > 1, pid != helperPID else { return EPERM }
        return nil
    }
}

/// The task-sample payload: JSON of pid → [resident bytes, CPU nanoseconds].
enum HelperWire {
    static func encodeSamples(_ samples: [pid_t: ProcTaskSample]) -> Data {
        let plain = Dictionary(uniqueKeysWithValues: samples.map { (String($0.key), [$0.value.residentBytes, $0.value.cpuTimeNanos]) })
        return (try? JSONEncoder().encode(plain)) ?? Data()
    }

    static func encodeInspection(_ inspection: PrivilegedInspection) -> Data {
        (try? JSONEncoder().encode(inspection)) ?? Data()
    }

    static func decodeInspection(_ data: Data) -> PrivilegedInspection? {
        try? JSONDecoder().decode(PrivilegedInspection.self, from: data)
    }

    static func decodeSamples(_ data: Data) -> [pid_t: ProcTaskSample]? {
        guard let plain = try? JSONDecoder().decode([String: [UInt64]].self, from: data) else { return nil }
        var samples: [pid_t: ProcTaskSample] = [:]
        for (key, values) in plain {
            guard let pid = pid_t(key), values.count == 2 else { continue }
            samples[pid] = ProcTaskSample(residentBytes: values[0], cpuTimeNanos: values[1])
        }
        return samples
    }
}
