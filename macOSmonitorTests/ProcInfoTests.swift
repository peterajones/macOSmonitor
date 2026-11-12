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

    @Test func displayNameFallsBackFromProcNameToPathToPID() {
        #expect(ProcInfo.displayName(procName: "Finder", path: "/x/Other", pid: 5) == "Finder")
        #expect(ProcInfo.displayName(procName: nil,
                                     path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
                                     pid: 625) == "WindowServer")
        #expect(ProcInfo.displayName(procName: "", path: "/usr/libexec/cloudd", pid: 9) == "cloudd")
        #expect(ProcInfo.displayName(procName: nil, path: nil, pid: 77) == "(pid 77)")
        #expect(ProcInfo.displayName(procName: nil, path: "/", pid: 78) == "(pid 78)")
    }

    /// Integration: proc_name is denied for WindowServer on this Mac, yet it gets its name.
    @Test func windowServerIsNamedNotNumbered() throws {
        let pid = try #require(sut.listPIDs().first { sut.path(pid: $0)?.hasSuffix("/WindowServer") == true })
        #expect(sut.name(pid: pid) == "WindowServer")
    }

    /// Across the whole system, only processes whose path is also unreadable may stay numbered.
    @Test func numberedNamesOnlyWhereThePathIsUnreadable() {
        let numbered = sut.listPIDs().filter { sut.name(pid: $0).hasPrefix("(pid ") }
        #expect(numbered.allSatisfy { sut.path(pid: $0) == nil }, "\(numbered.prefix(5))")
    }
}

