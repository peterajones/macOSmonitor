import Darwin

/// A signal the user can send to a process from the Process menu, toolbar or context menu.
enum ProcessSignal: CaseIterable, Sendable {
    case terminate   // Quit
    case kill        // Force Quit
    case stop        // Pause
    case resume      // Resume
    case hangUp      // Hang Up

    var number: Int32 {
        switch self {
        case .terminate: SIGTERM
        case .kill:      SIGKILL
        case .stop:      SIGSTOP
        case .resume:    SIGCONT
        case .hangUp:    SIGHUP
        }
    }

    /// The verb on menu items and the confirmation button.
    var actionTitle: String {
        switch self {
        case .terminate: "Quit"
        case .kill:      "Force Quit"
        case .stop:      "Pause"
        case .resume:    "Resume"
        case .hangUp:    "Hang Up"
        }
    }

    /// The signals under "Send Signal" (Quit and Force Quit have their own items).
    static let sendSignalMenu: [ProcessSignal] = [.stop, .resume, .hangUp]

    /// Submenu title, naming the signal for people who know it by that name.
    var menuTitle: String {
        switch self {
        case .terminate: "Quit (SIGTERM)"
        case .kill:      "Force Quit (SIGKILL)"
        case .stop:      "Pause (SIGSTOP)"
        case .resume:    "Resume (SIGCONT)"
        case .hangUp:    "Hang Up (SIGHUP)"
        }
    }

    /// Resume only continues a paused process, so it acts at once; everything else asks.
    var needsConfirmation: Bool { self != .resume }

    func confirmTitle(name: String) -> String { "\(actionTitle) “\(name)”?" }

    func confirmMessage(name: String, pid: pid_t) -> String {
        switch self {
        case .terminate:
            "“\(name)” (PID \(pid)) will be asked to quit."
        case .kill:
            "Force-quitting “\(name)” (PID \(pid)) ends it immediately; unsaved work is lost."
        case .stop:
            "“\(name)” (PID \(pid)) will be paused (SIGSTOP) until you resume it. A paused app stops responding."
        case .resume:
            "“\(name)” (PID \(pid)) will be resumed (SIGCONT)."
        case .hangUp:
            "“\(name)” (PID \(pid)) will be sent SIGHUP. Many background services reload their settings; most other programs quit."
        }
    }

    /// The batch dialog's title: "Quit 6 processes?"
    func confirmTitle(count: Int) -> String { "\(actionTitle) \(count) processes?" }

    /// The batch dialog's message; `groupedNames` is `ProcessBatch.groupedNames`.
    func confirmMessage(groupedNames names: String, count: Int) -> String {
        switch self {
        case .terminate:
            "These processes will be asked to quit: \(names)."
        case .kill:
            "Force-quitting ends these processes immediately; unsaved work is lost: \(names)."
        case .stop:
            "These processes will be paused (SIGSTOP) until you resume them: \(names)."
        case .resume:
            "These processes will be resumed (SIGCONT): \(names)."
        case .hangUp:
            "These processes will be sent SIGHUP: \(names). Many background services reload their settings; most other programs quit."
        }
    }

    /// Added to a confirmation when some selected processes won't be signalled.
    static func skippedNote(_ count: Int) -> String {
        count == 1
            ? "1 selected process can’t be signalled and will be left alone."
            : "\(count) selected processes can’t be signalled and will be left alone."
    }
}

/// Result of attempting to signal a process.
enum TerminationResult: Equatable, Sendable {
    case success
    case denied           // EPERM — not our process
    case noSuchProcess    // ESRCH — already gone
    case refusedSelfPause // pausing ourselves would freeze the app with nothing to resume it
    case failure(String)  // any other errno, human-readable
}

/// Isolates the `kill()` syscall behind a protocol so the model can be tested with a fake.
protocol ProcessTerminating: Sendable {
    func send(_ signal: ProcessSignal, to pid: pid_t) -> TerminationResult
}

struct ProcessTerminator: ProcessTerminating {
    /// This app's own PID. Injectable so the self-pause guard can be tested on a child
    /// process instead of freezing the test host.
    var ownPID: pid_t = getpid()

    func send(_ signal: ProcessSignal, to pid: pid_t) -> TerminationResult {
        // Guard against POSIX kill()'s special-pid semantics: pid == 0 signals the
        // caller's whole process group, pid == -1 broadcasts to every process we can
        // signal, and pid < -1 targets a process group. We only ever signal a
        // single real process, so anything <= 0 is rejected before it reaches kill().
        guard pid > 0 else { return .noSuchProcess }
        guard !(signal == .stop && pid == ownPID) else { return .refusedSelfPause }

        if kill(pid, signal.number) == 0 { return .success }
        switch errno {
        case EPERM: return .denied
        case ESRCH: return .noSuchProcess
        default:    return .failure(String(cString: strerror(errno)))
        }
    }
}
