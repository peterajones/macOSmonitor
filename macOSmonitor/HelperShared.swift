import Foundation
import Darwin

// Compiled into BOTH the app and macOSmonitorHelper (target membership ticked for each): the
// two sides of the XPC connection must agree on these names and the message protocol.

enum HelperConstants {
    /// launchd label and Mach service name; also the plist's file name without ".plist".
    static let machServiceName = "ca.peter-jones.macOSmonitor.helper"
    static let plistName = "ca.peter-jones.macOSmonitor.helper.plist"
    /// Bumped when the protocol changes, so the app can tell an out-of-date helper.
    static let protocolVersion = 1

    /// The only client the helper obeys: this app, signed by Peter's team. Without this, any
    /// process on the Mac could ask a root daemon to kill things.
    static let clientRequirement =
        #"anchor apple generic and identifier "ca.peter-jones.macOSmonitor" and certificate leaf[subject.OU] = "8QQC2WMRHS""#
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
}

/// What the helper will and won't do, kept apart from the XPC plumbing so it's testable.
enum HelperRules {
    /// The signals the app sends (Quit, Force Quit, Pause, Resume, Hang Up).
    static let allowedSignals: Set<Int32> = [SIGTERM, SIGKILL, SIGSTOP, SIGCONT, SIGHUP]

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
