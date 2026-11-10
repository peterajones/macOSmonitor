import Testing
import Darwin
import Foundation
@testable import macOSmonitor

struct ProcessTerminatorTests {
    let sut = ProcessTerminator()

    private func launchSleep(_ seconds: String = "60") throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = [seconds]
        try proc.run()
        return proc
    }

    /// The kernel's status for `pid` as the inspector shows it, polled briefly because a
    /// signal's effect is not always visible the instant kill() returns.
    private func status(of pid: pid_t, becomes expected: String) async throws -> String? {
        var latest: String?
        for _ in 0..<20 {
            latest = ProcInfo().details(pid: pid)?.status
            if latest == expected { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        return latest
    }

    @Test func terminatesAChildProcessWithSIGTERM() throws {
        let proc = try launchSleep()
        #expect(sut.send(.terminate, to: proc.processIdentifier) == .success)

        proc.waitUntilExit()          // reap the child; returns promptly after SIGTERM
        #expect(proc.terminationReason == .uncaughtSignal)
        #expect(proc.terminationStatus == SIGTERM)
    }

    @Test func pauseStopsAChildAndResumeContinuesIt() async throws {
        let proc = try launchSleep()
        defer { proc.terminate(); proc.waitUntilExit() }
        let pid = proc.processIdentifier

        #expect(sut.send(.stop, to: pid) == .success)
        #expect(try await status(of: pid, becomes: "Stopped") == "Stopped")

        #expect(sut.send(.resume, to: pid) == .success)
        // sleep goes straight back to sleeping; anything but Stopped means it resumed.
        #expect(try await status(of: pid, becomes: "Sleeping") != "Stopped")
    }

    @Test func hangUpEndsAProgramThatDoesNotHandleIt() throws {
        let proc = try launchSleep()
        #expect(sut.send(.hangUp, to: proc.processIdentifier) == .success)

        proc.waitUntilExit()
        #expect(proc.terminationReason == .uncaughtSignal)
        #expect(proc.terminationStatus == SIGHUP)   // not SIGTERM: the signal number is right
    }

    /// Pausing our own process would freeze the app with nothing left to resume it. The
    /// guard is exercised by telling a sender that a child is "its own" pid, so a broken
    /// guard pauses the child rather than hanging the test run.
    @Test func refusesToPauseItself() async throws {
        let proc = try launchSleep()
        defer { proc.terminate(); proc.waitUntilExit() }
        let pid = proc.processIdentifier
        let sender = ProcessTerminator(ownPID: pid)

        #expect(sender.send(.stop, to: pid) == .refusedSelfPause)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ProcInfo().details(pid: pid)?.status != "Stopped")

        // Every other signal to "itself" is still allowed (Quit is how you'd stop the app).
        #expect(sender.send(.resume, to: pid) == .success)
    }

    // Only meaningful as a non-root user; skipped under root so we never signal launchd as root.
    @Test(.enabled(if: getuid() != 0))
    func deniedForRootOwnedProcess() {
        #expect(sut.send(.terminate, to: 1) == .denied)   // pid 1 = launchd
    }

    // POSIX kill() treats pid 0 / -1 / negative as process-group or broadcast targets.
    // The shim must reject these before calling kill(), never signalling a group.
    @Test(arguments: [pid_t(0), pid_t(-1), pid_t(-1000)])
    func rejectsNonPositivePIDsWithoutSignalling(_ pid: pid_t) {
        #expect(sut.send(.kill, to: pid) == .noSuchProcess)
    }

    @Test func noSuchProcessForReapedChild() throws {
        let proc = try launchSleep("0")
        let pid = proc.processIdentifier
        proc.waitUntilExit()          // child exits and is reaped; pid is now gone

        #expect(sut.send(.terminate, to: pid) == .noSuchProcess)
    }
}

struct ProcessSignalTests {
    @Test func onlyResumeSkipsConfirmation() {
        let unconfirmed = ProcessSignal.allCases.filter { !$0.needsConfirmation }
        #expect(unconfirmed == [.resume])
    }

    @Test func confirmationNamesTheProcessAndPID() {
        for signal in ProcessSignal.allCases where signal.needsConfirmation {
            #expect(signal.confirmTitle(name: "Safari").contains("“Safari”"))
            #expect(signal.confirmMessage(name: "Safari", pid: 4321).contains("4321"))
        }
    }
}
