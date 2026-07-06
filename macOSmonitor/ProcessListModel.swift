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
    /// Open network sockets for the selected process; empty when none selected or denied.
    private(set) var selectedPorts: [ProcessPort] = []
    /// Latest system-wide vitals for the header; nil until the first sample.
    private(set) var vitals: SystemVitals?

    private let sampler: any ProcessSampling
    private let terminator: any ProcessTerminating
    private let detailProvider: any ProcessDetailProviding
    private let portProvider: any ProcessPortProviding
    private let vitalsSampler: any SystemVitalsSampling
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(),
         terminator: any ProcessTerminating = ProcessTerminator(),
         detailProvider: any ProcessDetailProviding = ProcInfo(),
         portProvider: any ProcessPortProviding = ProcInfo(),
         vitalsSampler: any SystemVitalsSampling = SystemVitalsSampler(),
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.terminator = terminator
        self.detailProvider = detailProvider
        self.portProvider = portProvider
        self.vitalsSampler = vitalsSampler
        self.interval = interval
    }

    /// One sample → publish rows, then refresh the selected process's details (live cadence).
    func refreshOnce() async {
        rows = await sampler.sample()
        refreshSelection()
        vitals = await vitalsSampler.sample()
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

    /// Refresh all selection-scoped inspector data (details + ports) for `selectedPID`.
    func refreshSelection() {
        refreshDetails()
        selectedPorts = selectedPID.map { portProvider.ports(pid: $0) } ?? []
    }

    /// The selected process's latest sampled row (nil when nothing is selected or it has
    /// vanished). Reading observable `rows`/`selectedPID` here means a view that observes this
    /// model re-renders as rows update each tick — the key to a live-updating inspector.
    var selectedRow: ProcessInfoRow? {
        guard let pid = selectedPID else { return nil }
        return rows.first { $0.id == pid }
    }
}
