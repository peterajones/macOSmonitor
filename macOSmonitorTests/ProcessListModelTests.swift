import Testing
import Darwin
import Foundation
@testable import macOSmonitor

final class FakeSampler: ProcessSampling, @unchecked Sendable {
    var next: [ProcessInfoRow] = []
    private(set) var callCount = 0
    func sample() async -> [ProcessInfoRow] { callCount += 1; return next }
}

final class FakeTerminator: ProcessTerminating, @unchecked Sendable {
    private(set) var lastPID: pid_t?
    private(set) var lastForce: Bool?
    var result: TerminationResult = .success
    func terminate(pid: pid_t, force: Bool) -> TerminationResult {
        lastPID = pid; lastForce = force; return result
    }
}

final class FakeDetailProvider: ProcessDetailProviding, @unchecked Sendable {
    var result: ProcessDetails?
    private(set) var lastPID: pid_t?
    func details(pid: pid_t) -> ProcessDetails? { lastPID = pid; return result }
}

@MainActor
struct ProcessListModelTests {
    @Test func refreshOnceReplacesRowsFromSampler() async {
        let fake = FakeSampler()
        fake.next = [ProcessInfoRow(pid: 1, name: "a", cpuPercent: 12, memoryBytes: 2048)]
        let model = ProcessListModel(sampler: fake)

        #expect(model.rows.isEmpty)
        await model.refreshOnce()

        #expect(fake.callCount == 1)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.name == "a")
    }

    @Test func terminateForwardsSignalChoiceAndReturnsResult() async {
        let fake = FakeTerminator()
        fake.result = .denied
        let model = ProcessListModel(sampler: FakeSampler(), terminator: fake)

        let result = model.terminate(pid: 4321, force: true)

        #expect(fake.lastPID == 4321)
        #expect(fake.lastForce == true)
        #expect(result == .denied)
    }

    @Test func refreshDetailsPublishesForSelectedPID() {
        let detail = ProcessDetails(path: "/bin/x", parentPID: 1,
                                    startDate: Date(timeIntervalSince1970: 0),
                                    threadCount: 3, user: "me", status: "Running")
        let fake = FakeDetailProvider()
        fake.result = detail
        let model = ProcessListModel(sampler: FakeSampler(), detailProvider: fake)

        model.selectedPID = 55
        model.refreshDetails()
        #expect(fake.lastPID == 55)
        #expect(model.selectedDetails == detail)

        model.selectedPID = nil
        model.refreshDetails()
        #expect(model.selectedDetails == nil)
    }

    @Test func selectedRowResolvesFromRowsBySelectedPID() async {
        let fake = FakeSampler()
        fake.next = [
            ProcessInfoRow(pid: 1, name: "a", cpuPercent: nil, memoryBytes: 100),
            ProcessInfoRow(pid: 2, name: "b", cpuPercent: nil, memoryBytes: 200),
        ]
        let model = ProcessListModel(sampler: fake)
        await model.refreshOnce()

        #expect(model.selectedRow == nil)              // nothing selected

        model.selectedPID = 2
        #expect(model.selectedRow?.name == "b")        // resolves the matching row

        model.selectedPID = 999
        #expect(model.selectedRow == nil)              // selected pid no longer present
    }
}
