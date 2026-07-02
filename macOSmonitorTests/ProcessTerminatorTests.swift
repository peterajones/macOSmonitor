import Testing
import Darwin
import Foundation
@testable import macOSmonitor

struct ProcessTerminatorTests {
    let sut = ProcessTerminator()

    @Test func terminatesAChildProcessWithSIGTERM() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["60"]
        try proc.run()
        let pid = pid_t(proc.processIdentifier)

        let result = sut.terminate(pid: pid, force: false)
        #expect(result == .success)

        proc.waitUntilExit()          // reap the child; returns promptly after SIGTERM
        #expect(proc.isRunning == false)
    }

    // Only meaningful as a non-root user; skipped under root so we never signal launchd as root.
    @Test(.enabled(if: getuid() != 0))
    func deniedForRootOwnedProcess() {
        #expect(sut.terminate(pid: 1, force: false) == .denied)   // pid 1 = launchd
    }

    @Test func noSuchProcessForReapedChild() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["0"]
        try proc.run()
        let pid = pid_t(proc.processIdentifier)
        proc.waitUntilExit()          // child exits and is reaped; pid is now gone

        #expect(sut.terminate(pid: pid, force: false) == .noSuchProcess)
    }
}
