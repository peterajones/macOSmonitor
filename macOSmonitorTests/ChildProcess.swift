import Darwin
import Foundation

/// A child process for tests: launched with `posix_spawn`, waited for with `waitpid`.
///
/// Why not Foundation's `Process`: its `waitUntilExit()` doesn't ask the kernel. It spins a run
/// loop until Foundation delivers an exit notification, and from Swift-concurrency contexts
/// that notification sometimes never arrives. On 2026-11-12 it hung the test suite (once in a
/// normal run, and within a minute in a 40× repeat of the process-spawning suites), and a
/// standalone 30-line program hung the same way, with the child already gone. `waitpid` returns
/// exactly when the kernel has the exit, with no run loop involved.
final class ChildProcess: @unchecked Sendable {
    enum Exit: Equatable, Sendable {
        case exited(Int32)     // normal exit with this status code
        case signaled(Int32)   // killed by this signal
    }

    let pid: pid_t
    private var exit: Exit?
    private let lock = NSLock()

    /// Launches `path` with `arguments`. `environment` replaces the parent's when given.
    init(_ path: String, _ arguments: [String] = [], environment: [String: String]? = nil) throws {
        let argv = [path] + arguments
        let envp = environment.map { $0.map { "\($0.key)=\($0.value)" } }

        func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
            let pointers = strings.map { strdup($0) } + [nil]
            defer { pointers.forEach { free($0) } }
            return body(pointers)
        }

        // A spawned child inherits the parent's ignored and blocked signals, and the test host
        // ignores some (SIGTERM and SIGHUP went unanswered for 60 s without this). Like
        // Foundation's Process, restore every signal's default action and block none.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var spawned: pid_t = 0
        let result: Int32 = withCStrings(argv) { argvPointers in
            if let envp {
                return withCStrings(envp) { envPointers in
                    posix_spawn(&spawned, path, nil, &attributes, argvPointers, envPointers)
                }
            }
            return posix_spawn(&spawned, path, nil, &attributes, argvPointers, environ)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "posix_spawn \(path): \(String(cString: strerror(result)))"])
        }
        pid = spawned
    }

    func signal(_ number: Int32) {
        lock.lock(); defer { lock.unlock() }
        if exit == nil { Darwin.kill(pid, number) }   // never signal a reaped (possibly reused) pid
    }

    /// Blocks until the child exits, reaps it, and returns how it ended. Safe to call again.
    @discardableResult
    func wait() -> Exit {
        lock.lock(); defer { lock.unlock() }
        if let exit { return exit }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let decoded = Self.decode(status)
        exit = decoded
        return decoded
    }

    /// SIGKILL and reap. SIGKILL also ends a stopped child, which SIGTERM would not until it
    /// was continued.
    func kill() {
        signal(SIGKILL)
        wait()
    }

    /// The `WIFEXITED` / `WTERMSIG` macros aren't available in Swift; this is their arithmetic.
    static func decode(_ status: Int32) -> Exit {
        let low = status & 0x7f
        return low == 0 ? .exited((status >> 8) & 0xff) : .signaled(low)
    }

    /// A test that forgets to wait must not leave a `sleep 60` behind.
    deinit {
        if exit == nil {
            Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }
}
