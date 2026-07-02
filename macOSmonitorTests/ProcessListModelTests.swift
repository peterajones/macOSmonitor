import Testing
import Darwin
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
}
