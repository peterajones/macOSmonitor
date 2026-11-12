import Darwin

/// Result of attempting to change a process's nice value.
enum ReniceResult: Equatable, Sendable {
    case success
    case denied           // EPERM — not our process
    case needsAdmin       // EACCES — lowering nice (raising priority) needs root
    case noSuchProcess    // ESRCH — already gone
    case failure(String)  // any other errno, human-readable

    /// Message for the inspector, or nil on success.
    func message(name: String) -> String? {
        switch self {
        case .success:          nil
        case .denied:           "Couldn’t change the priority of “\(name)”: permission denied."
        case .needsAdmin:       "Raising a process’s priority needs administrator rights."
        case .noSuchProcess:    "“\(name)” is no longer running."
        case .failure(let why): "Couldn’t change the priority of “\(name)”: \(why)."
        }
    }
}

/// Reads and sets a process's nice value (-20 highest priority … 20 lowest).
/// Isolates `getpriority`/`setpriority` behind a protocol so the model can be tested with a fake.
protocol ProcessPriorityProviding: Sendable {
    /// The current nice value, or nil when the process is gone or unreadable.
    func nice(pid: pid_t) -> Int32?
    func setNice(_ value: Int32, pid: pid_t) -> ReniceResult
}

/// What the user may pick in the inspector, and what the confirmation says about it.
enum Nice {
    /// PRIO_MIN...PRIO_MAX. Not Swift-visible as constants on every SDK, so spelled out.
    static let fullRange: ClosedRange<Int32> = -20...20

    /// The values the stepper offers. Without root, the kernel only lets nice go up
    /// (EACCES otherwise), so the floor is the current value: offering lower values would
    /// only ever produce an error.
    static func allowedRange(current: Int32, isRoot: Bool) -> ClosedRange<Int32> {
        isRoot ? fullRange : min(max(current, fullRange.lowerBound), fullRange.upperBound)...fullRange.upperBound
    }

    static func confirmTitle(name: String, value: Int32) -> String {
        "Set “\(name)” to nice \(value)?"
    }

    /// Raising nice without root is one-way, so the message says so before the user commits.
    static func confirmMessage(name: String, pid: pid_t, from current: Int32, to value: Int32,
                               isRoot: Bool) -> String {
        let direction = value > current ? "lower" : "higher"
        var message = "“\(name)” (PID \(pid)) will run at \(direction) priority (nice \(current) → \(value))."
        if value > current && !isRoot {
            message += " You can’t undo this without administrator rights: only raising the nice value is allowed."
        }
        return message
    }
}

struct ProcessPriority: ProcessPriorityProviding {
    func nice(pid: pid_t) -> Int32? {
        // who == 0 means "the calling process" to getpriority, so reject it like kill()'s
        // special pids; we only ever address one real process.
        guard pid > 0 else { return nil }
        // -1 is a legal nice value, so errno is the only way to tell it from failure.
        errno = 0
        let value = getpriority(PRIO_PROCESS, id_t(pid))
        return (value == -1 && errno != 0) ? nil : value
    }

    func setNice(_ value: Int32, pid: pid_t) -> ReniceResult {
        guard pid > 0 else { return .noSuchProcess }   // 0 would renice ourselves
        guard Nice.fullRange.contains(value) else { return .failure("nice must be between -20 and 20") }

        if setpriority(PRIO_PROCESS, id_t(pid), value) == 0 { return .success }
        switch errno {
        case EPERM:  return .denied
        case EACCES: return .needsAdmin
        case ESRCH:  return .noSuchProcess
        default:     return .failure(String(cString: strerror(errno)))
        }
    }
}
