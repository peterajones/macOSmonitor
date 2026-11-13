import Testing
import Darwin
@testable import macOSmonitor

/// A visible row; `signallable: false` gives it no memory reading, which is how the sampler
/// marks a process we may not signal (`canTerminate == false`).
private func row(_ pid: pid_t, _ name: String, signallable: Bool = true) -> ProcessInfoRow {
    ProcessInfoRow(pid: pid, name: name, cpuPercent: nil, memoryBytes: signallable ? 1 : nil)
}

struct ProcessBatchTests {
    // MARK: - Targets

    @Test func hiddenAndExitedPIDsAreIgnoredNotSkipped() {
        let batch = ProcessBatch.make(pids: [1, 2, 3], visibleRows: [row(2, "node")], ownPID: 999)
        #expect(batch.targets == [SignalTarget(pid: 2, name: "node")])
        #expect(batch.skippedCount == 0)
    }

    @Test func unsignallableVisibleRowsAreSkipped() {
        let batch = ProcessBatch.make(pids: [1, 2],
                                      visibleRows: [row(1, "node"), row(2, "launchd", signallable: false)],
                                      ownPID: 999)
        #expect(batch.targets.map(\.pid) == [1])
        #expect(batch.skippedCount == 1)
    }

    @Test func targetsFollowVisibleOrder() {
        let batch = ProcessBatch.make(pids: [1, 2, 3], visibleRows: [row(3, "c"), row(1, "a"), row(2, "b")], ownPID: 999)
        #expect(batch.targets.map(\.pid) == [3, 1, 2])
    }

    @Test func ownProcessIsATargetOnlyWhenAlone() {
        #expect(ProcessBatch.make(pids: [50], visibleRows: [row(50, "macOSmonitor")], ownPID: 50)
            .targets.map(\.pid) == [50])
        // Hidden companions don't count.
        #expect(ProcessBatch.make(pids: [50, 7], visibleRows: [row(50, "macOSmonitor")], ownPID: 50)
            .targets.map(\.pid) == [50])

        let withOther = ProcessBatch.make(pids: [50, 7], visibleRows: [row(50, "macOSmonitor"), row(7, "node")], ownPID: 50)
        #expect(withOther.targets.map(\.pid) == [7])
        #expect(withOther.skippedCount == 1)

        // An unsignallable companion still means "not alone".
        let withRoot = ProcessBatch.make(pids: [50, 1],
                                         visibleRows: [row(50, "macOSmonitor"), row(1, "launchd", signallable: false)],
                                         ownPID: 50)
        #expect(withRoot.targets.isEmpty)
        #expect(withRoot.skippedCount == 2)
    }

    @Test func groupedNamesCountsMostCommonFirst() {
        let batch = ProcessBatch(targets: [.init(pid: 1, name: "zsh"), .init(pid: 2, name: "node"),
                                           .init(pid: 3, name: "npm"), .init(pid: 4, name: "node"),
                                           .init(pid: 5, name: "esbuild"), .init(pid: 6, name: "Awk"),
                                           .init(pid: 7, name: "node")],
                                 skippedCount: 0)
        // Ties (once each) go alphabetically, ignoring case, whatever order they arrived in:
        // four of them, so a missing tie-break can't pass by luck of dictionary order.
        #expect(batch.groupedNames == "node ×3, Awk, esbuild, npm, zsh")
    }

    // MARK: - Confirmation

    @Test func noTargetsMeansNoRequest() {
        #expect(PendingTermination.request(for: ProcessBatch(targets: [], skippedCount: 2), signal: .terminate) == nil)
    }

    @Test func singleTargetKeepsTodaysDialog() throws {
        let request = try #require(PendingTermination.request(
            for: ProcessBatch(targets: [.init(pid: 42, name: "node")], skippedCount: 0), signal: .terminate))
        #expect(request.title == "Quit “node”?")
        #expect(request.message == "“node” (PID 42) will be asked to quit.")
    }

    @Test func singleTargetWithSkippedAddsTheNote() throws {
        let request = try #require(PendingTermination.request(
            for: ProcessBatch(targets: [.init(pid: 42, name: "node")], skippedCount: 1), signal: .terminate))
        #expect(request.message == "“node” (PID 42) will be asked to quit.\n\n1 selected process can’t be signalled and will be left alone.")
    }

    @Test func severalTargetsUseTheBatchDialog() throws {
        let request = try #require(PendingTermination.request(
            for: ProcessBatch(targets: [.init(pid: 1, name: "node"), .init(pid: 2, name: "node")], skippedCount: 3),
            signal: .kill))
        #expect(request.title == "Force Quit 2 processes?")
        #expect(request.message == "Force-quitting ends these processes immediately; unsaved work is lost: node ×2.\n\n3 selected processes can’t be signalled and will be left alone.")
    }

    // MARK: - Outcome

    @Test func allSucceededHasNoMessage() {
        let outcomes: [SignalOutcome] = [.init(target: .init(pid: 1, name: "a"), result: .success),
                                         .init(target: .init(pid: 2, name: "b"), result: .success)]
        #expect(SignalOutcome.failureMessage(outcomes, signal: .terminate) == nil)
    }

    @Test func singleFailureKeepsTodaysWording() {
        func message(_ result: TerminationResult, _ signal: ProcessSignal = .terminate) -> String? {
            SignalOutcome.failureMessage([.init(target: .init(pid: 1, name: "x"), result: result)], signal: signal)
        }
        #expect(message(.denied) == "Couldn’t quit “x”: permission denied.")
        #expect(message(.noSuchProcess) == "“x” is no longer running.")
        #expect(message(.refusedSelfPause, .stop) == "macOSmonitor can’t pause itself: nothing would be left to resume it.")
        #expect(message(.failure("Bad thing"), .kill) == "Couldn’t force quit “x”: Bad thing.")
    }

    @Test func batchFailuresAreListedOnce() {
        let outcomes: [SignalOutcome] = [
            .init(target: .init(pid: 1, name: "node"), result: .success),
            .init(target: .init(pid: 2, name: "helper"), result: .denied),
            .init(target: .init(pid: 3, name: "node"), result: .success),
            .init(target: .init(pid: 4, name: "node"), result: .noSuchProcess)]
        #expect(SignalOutcome.failureMessage(outcomes, signal: .kill)
                == "Force Quit 2 of 4 processes. Couldn’t force quit: helper (permission denied); node (no longer running).")
    }

    // MARK: - Inspector summary

    @Test func summaryNeedsSeveralSelected() {
        #expect(SelectionSummary(pids: [1], visibleRows: [row(1, "node")]) == nil)
        #expect(SelectionSummary(pids: [], visibleRows: [row(1, "node")]) == nil)
    }

    @Test func summaryNamesVisibleRowsAndCountsHiddenOnes() throws {
        let summary = try #require(SelectionSummary(pids: [1, 2, 3, 4],
                                                    visibleRows: [row(1, "node"), row(2, "node"), row(9, "zsh")]))
        #expect(summary.title == "4 Processes Selected")
        #expect(summary.detail == "node ×2\n2 hidden by the current search or filter won’t be signalled.")
    }

    @Test func summaryWithNothingHiddenIsJustTheNames() throws {
        let summary = try #require(SelectionSummary(pids: [1, 2], visibleRows: [row(1, "node"), row(2, "npm")]))
        #expect(summary.detail == "node, npm")
    }

    @Test func summaryWithOneHiddenIsSingular() throws {
        let summary = try #require(SelectionSummary(pids: [1, 2], visibleRows: [row(1, "node")]))
        #expect(summary.detail == "node\n1 hidden by the current search or filter won’t be signalled.")
    }
}
