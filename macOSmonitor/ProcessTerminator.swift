import Darwin

/// Result of attempting to terminate a process.
enum TerminationResult: Equatable, Sendable {
    case success
    case denied          // EPERM — not our process
    case noSuchProcess   // ESRCH — already gone
    case failure(String) // any other errno, human-readable
}

/// Isolates the `kill()` syscall behind a protocol so the model can be tested with a fake.
protocol ProcessTerminating: Sendable {
    func terminate(pid: pid_t, force: Bool) -> TerminationResult
}

struct ProcessTerminator: ProcessTerminating {
    func terminate(pid: pid_t, force: Bool) -> TerminationResult {
        // Guard against POSIX kill()'s special-pid semantics: pid == 0 signals the
        // caller's whole process group, pid == -1 broadcasts to every process we can
        // signal, and pid < -1 targets a process group. We only ever terminate a
        // single real process, so anything <= 0 is rejected before it reaches kill().
        guard pid > 0 else { return .noSuchProcess }

        let signal = force ? SIGKILL : SIGTERM
        if kill(pid, signal) == 0 { return .success }
        switch errno {
        case EPERM: return .denied
        case ESRCH: return .noSuchProcess
        default:    return .failure(String(cString: strerror(errno)))
        }
    }
}
