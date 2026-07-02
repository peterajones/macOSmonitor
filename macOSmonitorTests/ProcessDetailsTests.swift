import Testing
import Darwin
@testable import macOSmonitor

struct ProcessDetailsTests {
    let sut = ProcInfo()

    @Test func detailsForSelfAreSane() {
        let details = sut.details(pid: getpid())
        #expect(details != nil)
        #expect((details?.threadCount ?? 0) >= 1)
        #expect((details?.parentPID ?? 0) > 0)
        #expect(details?.path?.isEmpty == false)
    }

    @Test func userMatchesCurrentUser() {
        let expected = getpwuid(getuid()).flatMap { $0.pointee.pw_name }.map { String(cString: $0) }
        #expect(sut.details(pid: getpid())?.user == expected)
    }

    // Root-owned processes deny PROC_PIDTASKALLINFO to a normal user; skipped under root.
    @Test(.enabled(if: getuid() != 0))
    func deniedProcessHasNoDetails() {
        #expect(sut.details(pid: 1) == nil)   // pid 1 = launchd
    }
}
