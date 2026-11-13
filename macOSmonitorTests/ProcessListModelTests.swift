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
    private(set) var lastSignal: ProcessSignal?
    /// Every signal sent, in order.
    private(set) var sent: [(signal: ProcessSignal, pid: pid_t)] = []
    var result: TerminationResult = .success
    func send(_ signal: ProcessSignal, to pid: pid_t) -> TerminationResult {
        lastPID = pid; lastSignal = signal; sent.append((signal, pid)); return result
    }
}

final class FakeDetailProvider: ProcessDetailProviding, @unchecked Sendable {
    var result: ProcessDetails?
    private(set) var lastPID: pid_t?
    func details(pid: pid_t) -> ProcessDetails? { lastPID = pid; return result }
}

final class FakePortProvider: ProcessPortProviding, @unchecked Sendable {
    var result: [ProcessPort] = []
    private(set) var lastPID: pid_t?
    func ports(pid: pid_t) -> [ProcessPort] { lastPID = pid; return result }
}

final class FakeCommandLineProvider: ProcessCommandLineProviding, @unchecked Sendable {
    var result: ProcessCommandLine?
    private(set) var lastPID: pid_t?
    func commandLine(pid: pid_t) -> ProcessCommandLine? { lastPID = pid; return result }
}

final class FakePriorityProvider: ProcessPriorityProviding, @unchecked Sendable {
    var current: [pid_t: Int32] = [:]
    var setResult: ReniceResult = .success
    private(set) var lastSet: (value: Int32, pid: pid_t)?
    func nice(pid: pid_t) -> Int32? { current[pid] }
    func setNice(_ value: Int32, pid: pid_t) -> ReniceResult {
        lastSet = (value, pid)
        if setResult == .success { current[pid] = value }
        return setResult
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

    @Test func sendForwardsSignalChoiceAndReturnsResult() async {
        let fake = FakeTerminator()
        fake.result = .denied
        let model = ProcessListModel(sampler: FakeSampler(), terminator: fake)

        let result = model.send(.hangUp, to: 4321)

        #expect(fake.lastPID == 4321)
        #expect(fake.lastSignal == .hangUp)
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

    @Test func refreshSelectionPublishesPortsAndClearsWhenNoSelection() {
        let fake = FakePortProvider()
        fake.result = [ProcessPort(protocolName: "TCP", localAddress: "*", localPort: 80,
                                   remoteAddress: nil, remotePort: nil, state: "LISTEN")]
        let model = ProcessListModel(sampler: FakeSampler(), portProvider: fake)

        model.selectedPID = 7
        model.refreshSelection()
        #expect(fake.lastPID == 7)
        #expect(model.selectedPorts.count == 1)

        model.selectedPID = nil
        model.refreshSelection()
        #expect(model.selectedPorts.isEmpty)
    }

    @Test func refreshSelectionPublishesCommandLineAndClearsWhenNoSelection() {
        let fake = FakeCommandLineProvider()
        let commandLine = ProcessCommandLine(arguments: ["/bin/x", "--verbose"], environment: ["A=1"])
        fake.result = commandLine
        let model = ProcessListModel(sampler: FakeSampler(), commandLineProvider: fake)

        model.selectedPID = 9
        model.refreshSelection()
        #expect(fake.lastPID == 9)
        #expect(model.selectedCommandLine == commandLine)

        model.selectedPID = nil
        model.refreshSelection()
        #expect(model.selectedCommandLine == nil)
    }

    @Test func revealedEnvironmentCollapsesWhenTheSelectionChanges() {
        let model = ProcessListModel(sampler: FakeSampler())
        #expect(model.isEnvironmentRevealed == false)   // collapsed by default

        model.selectedPID = 10
        model.isEnvironmentRevealed = true
        model.selectedPID = 10                          // re-set to the same process: stays open
        #expect(model.isEnvironmentRevealed == true)

        model.selectedPID = 11                          // another process: never shows its secrets
        #expect(model.isEnvironmentRevealed == false)

        model.isEnvironmentRevealed = true
        model.selectedPID = nil                         // deselecting collapses too
        #expect(model.isEnvironmentRevealed == false)
    }

    /// The loop moved to ContentView in M11, so it now outlives ProcessesView.
    /// Cancellation must still stop it, or navigating away would leak a sampler.
    @Test func runStopsSamplingAfterCancellation() async {
        let sampler = FakeSampler()
        let model = ProcessListModel(sampler: sampler, interval: .milliseconds(10))

        let task = Task { await model.run() }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = await task.value

        let countAtCancel = sampler.callCount
        #expect(countAtCancel > 0, "loop should have sampled at least once before cancelling")

        try? await Task.sleep(for: .milliseconds(80))
        #expect(sampler.callCount == countAtCancel, "loop kept sampling after cancellation")
    }

    // MARK: - Renice

    @Test func refreshSelectionPublishesNiceAndClearsWhenNoSelection() {
        let fake = FakePriorityProvider()
        fake.current = [12: 3]
        let model = ProcessListModel(sampler: FakeSampler(), priorityProvider: fake)

        model.selectedPID = 12
        model.refreshSelection()
        #expect(model.selectedNice == 3)

        model.selectedPID = nil
        model.refreshSelection()
        #expect(model.selectedNice == nil)
    }

    @Test func successfulReniceClearsTheDraftAndRereadsTheValue() {
        let fake = FakePriorityProvider()
        fake.current = [12: 0]
        let model = ProcessListModel(sampler: FakeSampler(), priorityProvider: fake)
        model.selectedPID = 12
        model.refreshSelection()
        model.niceDraft = 7
        model.reniceError = "stale"

        #expect(model.renice(12, name: "x", to: 7) == .success)
        #expect(fake.lastSet?.value == 7 && fake.lastSet?.pid == 12)
        #expect(model.selectedNice == 7)        // re-read, not left at 0
        #expect(model.niceDraft == nil)
        #expect(model.reniceError == nil)
    }

    @Test func failedReniceKeepsTheDraftAndShowsWhy() {
        let fake = FakePriorityProvider()
        fake.current = [12: 5]
        fake.setResult = .needsAdmin
        let model = ProcessListModel(sampler: FakeSampler(), priorityProvider: fake)
        model.selectedPID = 12
        model.refreshSelection()
        model.niceDraft = 2

        #expect(model.renice(12, name: "x", to: 2) == .needsAdmin)
        #expect(model.selectedNice == 5)
        #expect(model.niceDraft == 2)
        #expect(model.reniceError == ReniceResult.needsAdmin.message(name: "x"))
    }

    @Test func changingSelectionDropsTheDraftAndError() {
        let model = ProcessListModel(sampler: FakeSampler(), priorityProvider: FakePriorityProvider())
        model.selectedPID = 12
        model.niceDraft = 9
        model.reniceError = "nope"
        model.selectedPID = 12                  // same process: draft survives the 1 Hz re-set
        #expect(model.niceDraft == 9)

        model.selectedPID = 13                  // another process must never inherit the draft
        #expect(model.niceDraft == nil)
        #expect(model.reniceError == nil)
    }

    /// The dialog captures the PID; if the selection moved while it was open, the renice
    /// still goes to the confirmed process but must not write its result onto the new one.
    @Test func reniceForAProcessNoLongerSelectedLeavesTheInspectorAlone() {
        let fake = FakePriorityProvider()
        fake.current = [12: 0, 13: 4]
        fake.setResult = .denied
        let model = ProcessListModel(sampler: FakeSampler(), priorityProvider: fake)
        model.selectedPID = 13
        model.refreshSelection()
        model.niceDraft = 6

        #expect(model.renice(12, name: "old", to: 9) == .denied)
        #expect(fake.lastSet?.pid == 12)
        #expect(model.selectedNice == 4)
        #expect(model.niceDraft == 6)
        #expect(model.reniceError == nil)
    }

    // MARK: - Multi-selection

    @Test func selectedPIDIsTheSoleSelectionAndNilForSeveral() {
        let model = ProcessListModel(sampler: FakeSampler())
        model.selectedPIDs = [5]
        #expect(model.selectedPID == 5)
        model.selectedPIDs = [5, 6]
        #expect(model.selectedPID == nil)
        model.selectedPID = 7
        #expect(model.selectedPIDs == [7])
        model.selectedPID = nil
        #expect(model.selectedPIDs.isEmpty)
    }

    @Test func growingTheSelectionResetsInspectorState() {
        let model = ProcessListModel(sampler: FakeSampler())
        model.selectedPIDs = [5]
        model.isEnvironmentRevealed = true
        model.niceDraft = 4
        model.selectedPIDs = [5, 6]
        #expect(model.isEnvironmentRevealed == false)
        #expect(model.niceDraft == nil)
    }

    @Test func selectedRowsFollowRowOrder() async {
        let fake = FakeSampler()
        fake.next = [ProcessInfoRow(pid: 3, name: "c", cpuPercent: nil, memoryBytes: 1),
                     ProcessInfoRow(pid: 1, name: "a", cpuPercent: nil, memoryBytes: 1),
                     ProcessInfoRow(pid: 2, name: "b", cpuPercent: nil, memoryBytes: 1)]
        let model = ProcessListModel(sampler: fake)
        await model.refreshOnce()
        model.selectedPIDs = [2, 3, 99]
        #expect(model.selectedRows.map(\.pid) == [3, 2])
    }

    @Test func batchSendSkipsAPIDNowRunningSomethingElse() async {
        let sampler = FakeSampler()
        sampler.next = [ProcessInfoRow(pid: 1, name: "node", cpuPercent: nil, memoryBytes: 1),
                        ProcessInfoRow(pid: 2, name: "Safari", cpuPercent: nil, memoryBytes: 1)]
        let terminator = FakeTerminator()
        let model = ProcessListModel(sampler: sampler, terminator: terminator)
        await model.refreshOnce()

        // pid 2 was "node" when confirmed but is Safari now; pid 3 has gone.
        let outcomes = model.send(.terminate, to: [.init(pid: 1, name: "node"),
                                                   .init(pid: 2, name: "node"),
                                                   .init(pid: 3, name: "node")])
        #expect(terminator.sent.map(\.pid) == [1])
        #expect(outcomes.map(\.result) == [.success, .noSuchProcess, .noSuchProcess])
    }

    @Test func batchResumeSignalsEveryTarget() async {
        let sampler = FakeSampler()
        sampler.next = (1...3).map { ProcessInfoRow(pid: $0, name: "node", cpuPercent: nil, memoryBytes: 1) }
        let terminator = FakeTerminator()
        let model = ProcessListModel(sampler: sampler, terminator: terminator)
        await model.refreshOnce()

        _ = model.send(.resume, to: (1...3).map { SignalTarget(pid: $0, name: "node") })
        #expect(terminator.sent.map(\.pid) == [1, 2, 3])
        #expect(terminator.sent.allSatisfy { $0.signal == .resume })
    }

    @Test func refreshDropsExitedProcessesFromTheSelection() async {
        let sampler = FakeSampler()
        sampler.next = [ProcessInfoRow(pid: 1, name: "node", cpuPercent: nil, memoryBytes: 1),
                        ProcessInfoRow(pid: 2, name: "node", cpuPercent: nil, memoryBytes: 1)]
        let model = ProcessListModel(sampler: sampler)
        await model.refreshOnce()
        model.selectedPIDs = [1, 2]

        sampler.next = [ProcessInfoRow(pid: 2, name: "node", cpuPercent: nil, memoryBytes: 1)]
        await model.refreshOnce()
        #expect(model.selectedPIDs == [2])
        #expect(model.selectedPID == 2)            // the survivor gets the full inspector

        sampler.next = []
        await model.refreshOnce()
        #expect(model.selectedPIDs.isEmpty)        // all quit: back to "No Selection"
    }
}
