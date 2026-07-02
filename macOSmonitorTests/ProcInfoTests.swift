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

    @Test func nameForSelfIsNonEmpty() {
        #expect(!sut.name(pid: getpid()).isEmpty)
    }
}
