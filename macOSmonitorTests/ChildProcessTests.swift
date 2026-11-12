import Testing
import Darwin
@testable import macOSmonitor

/// The test helper itself: how a child ended must be decoded correctly, or every test that
/// relies on it (Quit sends SIGTERM, Hang Up sends SIGHUP…) would pass or fail for nothing.
struct ChildProcessTests {
    @Test func reportsANormalExitCode() throws {
        #expect(try ChildProcess("/bin/sh", ["-c", "exit 3"]).wait() == .exited(3))
        #expect(try ChildProcess("/usr/bin/true").wait() == .exited(0))
    }

    @Test func reportsTheSignalThatEndedIt() throws {
        let child = try ChildProcess("/bin/sleep", ["60"])
        child.signal(SIGHUP)
        #expect(child.wait() == .signaled(SIGHUP))
    }

    /// SIGTERM to a stopped process stays pending until it is continued; kill() must still
    /// end it promptly. (Foundation's terminate() sends SIGTERM.)
    @Test func killEndsAStoppedChild() throws {
        let child = try ChildProcess("/bin/sleep", ["60"])
        child.signal(SIGSTOP)
        child.kill()
        #expect(child.wait() == .signaled(SIGKILL))
    }

    /// After reaping, the pid may belong to someone else: signal() must not reach it.
    @Test func neverSignalsAReapedPID() throws {
        let child = try ChildProcess("/usr/bin/true")
        child.wait()
        child.signal(SIGKILL)                          // a no-op, not a kill of a reused pid
        #expect(child.wait() == .exited(0))            // and wait() stays answerable
    }

    @Test func passesExactlyTheGivenEnvironment() throws {
        let child = try ChildProcess("/bin/sh", ["-c", #"[ "$ONLY" = "this" ] && [ -z "$HOME" ]"#],
                                     environment: ["ONLY": "this"])
        #expect(child.wait() == .exited(0))
    }

    @Test func statusDecoding() {
        #expect(ChildProcess.decode(0) == .exited(0))
        #expect(ChildProcess.decode(3 << 8) == .exited(3))
        #expect(ChildProcess.decode(SIGTERM) == .signaled(SIGTERM))
    }

    @Test func missingExecutableThrows() {
        #expect(throws: (any Error).self) { try ChildProcess("/nonexistent/binary") }
    }
}
