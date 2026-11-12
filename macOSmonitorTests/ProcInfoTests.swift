import Testing
import Darwin
@testable import macOSmonitor

struct ProcInfoTests {
    let sut = ProcInfo()

    @Test func listPIDsIncludesOurOwnProcess() {
        #expect(sut.listPIDs().contains(getpid()))
    }

    @Test func sampleForSelfReportsMemory() {
        let sample = sut.sample(pid: getpid())
        #expect(sample != nil)
        #expect((sample?.residentBytes ?? 0) > 0)
    }

    /// Ownership must be readable for processes whose task info is denied (root's), or the
    /// system filter could not classify them.
    @Test(.enabled(if: getuid() != 0))
    func ownerIsReadableForOurOwnAndRootProcesses() {
        #expect(sut.owner(pid: getpid()) == getuid())
        #expect(sut.sample(pid: 1) == nil)          // task info denied for launchd...
        #expect(sut.owner(pid: 1) == 0)             // ...but its owner is not
    }

    @Test func nameForSelfIsNonEmpty() {
        #expect(!sut.name(pid: getpid()).isEmpty)
    }
}
