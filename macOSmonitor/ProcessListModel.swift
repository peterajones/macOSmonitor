import Foundation
import Observation

@MainActor
@Observable
final class ProcessListModel {
    private(set) var rows: [ProcessInfoRow] = []

    /// Currently selected process (single source of truth, bound to the table).
    var selectedPID: pid_t?
    /// Detail for the selected process; nil when nothing selected or access is denied.
    private(set) var selectedDetails: ProcessDetails?

    private let sampler: any ProcessSampling
    private let terminator: any ProcessTerminating
    private let detailProvider: any ProcessDetailProviding
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(),
         terminator: any ProcessTerminating = ProcessTerminator(),
         detailProvider: any ProcessDetailProviding = ProcInfo(),
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.terminator = terminator
        self.detailProvider = detailProvider
        self.interval = interval
    }

    /// One sample → publish rows, then refresh the selected process's details (live cadence).
    func refreshOnce() async {
        rows = await sampler.sample()
        refreshDetails()
    }

    /// Drives the dashboard. Owned by the view via `.task`, which cancels it on disappear.
    func run() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(for: interval)
        }
    }

    /// Send SIGTERM (force == false) or SIGKILL (force == true) to a process.
    func terminate(pid: pid_t, force: Bool) -> TerminationResult {
        terminator.terminate(pid: pid, force: force)
    }

    /// Refresh `selectedDetails` for the current `selectedPID` (nil if none/denied).
    func refreshDetails() {
        selectedDetails = selectedPID.flatMap { detailProvider.details(pid: $0) }
    }
}
