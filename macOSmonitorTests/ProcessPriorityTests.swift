import Testing
import Darwin
import Foundation
@testable import macOSmonitor

struct ProcessPriorityTests {
    let sut = ProcessPriority()

    /// A `sleep` child. ChildProcess, not Foundation's Process: see ChildProcess.swift for
    /// the waitUntilExit() hang this avoids.
    private func launchSleep(_ seconds: String = "60") throws -> ChildProcess {
        try ChildProcess("/bin/sleep", [seconds])
    }

    @Test func readsAndRaisesTheNiceValueOfAChild() throws {
        let proc = try launchSleep()
        defer { proc.kill() }
        let pid = proc.pid
        let before = try #require(sut.nice(pid: pid))

        // 7 rather than a round number, and relative to `before`, so a stubbed or
        // relative-increment implementation reads back something visibly different.
        let target = min(before + 7, 20)
        #expect(sut.setNice(target, pid: pid) == .success)
        #expect(sut.nice(pid: pid) == target)
    }

    /// Without root the kernel refuses to lower nice once raised (EACCES), which is why
    /// the inspector confirms before raising it.
    @Test(.enabled(if: getuid() != 0))
    func loweringNiceNeedsAdmin() throws {
        let proc = try launchSleep()
        defer { proc.kill() }
        let pid = proc.pid

        #expect(sut.setNice(10, pid: pid) == .success)
        #expect(sut.setNice(4, pid: pid) == .needsAdmin)
        #expect(sut.nice(pid: pid) == 10)
    }

    @Test(.enabled(if: getuid() != 0))
    func deniedForRootOwnedProcess() {
        #expect(sut.nice(pid: 1) != nil)                    // reading anyone's nice is allowed
        #expect(sut.setNice(19, pid: 1) == .denied)         // pid 1 = launchd
    }

    /// getpriority/setpriority treat who == 0 as "the calling process": renicing pid 0
    /// would renice this app. Must be rejected before the syscall.
    @Test(arguments: [pid_t(0), pid_t(-1)])
    func rejectsNonPositivePIDs(_ pid: pid_t) {
        let ownBefore = getpriority(PRIO_PROCESS, 0)
        #expect(sut.nice(pid: pid) == nil)
        #expect(sut.setNice(ownBefore + 1, pid: pid) == .noSuchProcess)
        #expect(getpriority(PRIO_PROCESS, 0) == ownBefore)
    }

    @Test func noSuchProcessForReapedChild() throws {
        let proc = try launchSleep("0")
        let pid = proc.pid
        proc.wait()

        #expect(sut.nice(pid: pid) == nil)
        #expect(sut.setNice(5, pid: pid) == .noSuchProcess)
    }

    @Test func rejectsValuesOutsideTheNiceRange() throws {
        let proc = try launchSleep()
        defer { proc.kill() }
        let pid = proc.pid

        // The kernel would silently clamp 25 to 20; refusing keeps what the UI shows honest.
        guard case .failure = sut.setNice(25, pid: pid) else {
            Issue.record("expected an out-of-range value to be refused"); return
        }
        #expect(sut.nice(pid: pid) != 20)
    }
}

struct NiceTests {
    @Test func withoutRootTheStepperCannotGoBelowTheCurrentValue() {
        #expect(Nice.allowedRange(current: 5, isRoot: false) == 5...20)
        #expect(Nice.allowedRange(current: -3, isRoot: false) == -3...20)
        #expect(Nice.allowedRange(current: 5, isRoot: true) == -20...20)
    }

    @Test func raisingWithoutRootWarnsThatItCannotBeUndone() {
        let raise = Nice.confirmMessage(name: "Xcode", pid: 812, from: 0, to: 10, isRoot: false)
        #expect(raise.contains("812"))
        #expect(raise.contains("0 → 10"))
        #expect(raise.contains("lower priority"))
        #expect(raise.contains("can’t undo"))

        let asRoot = Nice.confirmMessage(name: "Xcode", pid: 812, from: 0, to: 10, isRoot: true)
        #expect(!asRoot.contains("can’t undo"))

        let lower = Nice.confirmMessage(name: "Xcode", pid: 812, from: 10, to: 0, isRoot: true)
        #expect(lower.contains("higher priority"))
        #expect(!lower.contains("can’t undo"))
    }

    @Test func resultMessagesNameTheProcess() {
        #expect(ReniceResult.success.message(name: "Mail") == nil)
        for result in [ReniceResult.denied, .noSuchProcess, .failure("boom")] {
            #expect(result.message(name: "Mail")?.contains("“Mail”") == true)
        }
        #expect(ReniceResult.needsAdmin.message(name: "Mail")?.contains("administrator") == true)
    }
}
