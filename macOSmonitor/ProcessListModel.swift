import Foundation
import Observation

@MainActor
@Observable
final class ProcessListModel {
    private(set) var rows: [ProcessInfoRow] = []

    /// Currently selected process (single source of truth, bound to the table).
    var selectedPID: pid_t? {
        // Collapse the environment when the selection moves, so revealing one process's
        // variables (which often hold secrets) never reveals another's.
        didSet { if selectedPID != oldValue { isEnvironmentRevealed = false } }
    }
    /// Whether the inspector's Environment section is expanded. Collapsed by default.
    /// Held here rather than as view @State so the reset rule above is testable.
    var isEnvironmentRevealed = false
    /// Detail for the selected process; nil when nothing selected or access is denied.
    private(set) var selectedDetails: ProcessDetails?
    /// Open network sockets for the selected process; empty when none selected or denied.
    private(set) var selectedPorts: [ProcessPort] = []
    /// Arguments and environment for the selected process; nil when none selected or denied.
    private(set) var selectedCommandLine: ProcessCommandLine?

    private let sampler: any ProcessSampling
    private let terminator: any ProcessTerminating
    private let detailProvider: any ProcessDetailProviding
    private let portProvider: any ProcessPortProviding
    private let commandLineProvider: any ProcessCommandLineProviding
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(),
         terminator: any ProcessTerminating = ProcessTerminator(),
         detailProvider: any ProcessDetailProviding = ProcInfo(),
         portProvider: any ProcessPortProviding = ProcInfo(),
         commandLineProvider: any ProcessCommandLineProviding = ProcInfo(),
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.terminator = terminator
        self.detailProvider = detailProvider
        self.portProvider = portProvider
        self.commandLineProvider = commandLineProvider
        self.interval = interval
    }

    /// One sample → publish rows, then refresh the selected process's details (live cadence).
    func refreshOnce() async {
        rows = await sampler.sample()
        refreshSelection()
    }

    /// The `limit` highest-CPU rows, for the Summary dashboard's process card.
    func topByCPU(limit: Int) -> [ProcessInfoRow] {
        ProcessInfoRow.topByCPU(rows, limit: limit)
    }

    /// Drives the dashboard. Owned by the view via `.task`, which cancels it on disappear.
    func run() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(for: interval)
        }
    }

    /// Send `signal` (Quit, Force Quit, Pause, Resume, Hang Up) to a process.
    func send(_ signal: ProcessSignal, to pid: pid_t) -> TerminationResult {
        terminator.send(signal, to: pid)
    }

    /// Refresh `selectedDetails` for the current `selectedPID` (nil if none/denied).
    func refreshDetails() {
        selectedDetails = selectedPID.flatMap { detailProvider.details(pid: $0) }
    }

    /// Refresh all selection-scoped inspector data (details, ports, command line) for `selectedPID`.
    func refreshSelection() {
        refreshDetails()
        selectedPorts = selectedPID.map { portProvider.ports(pid: $0) } ?? []
        selectedCommandLine = selectedPID.flatMap { commandLineProvider.commandLine(pid: $0) }
    }

    /// The selected process's latest sampled row (nil when nothing is selected or it has
    /// vanished). Reading observable `rows`/`selectedPID` here means a view that observes this
    /// model re-renders as rows update each tick — the key to a live-updating inspector.
    var selectedRow: ProcessInfoRow? {
        guard let pid = selectedPID else { return nil }
        return rows.first { $0.id == pid }
    }
}
