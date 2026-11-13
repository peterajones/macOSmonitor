import Foundation
import Observation

@MainActor
@Observable
final class ProcessListModel {
    private(set) var rows: [ProcessInfoRow] = []

    /// The table's selection (single source of truth, bound to the table). Several rows can
    /// be selected for Quit / Force Quit; the inspector shows one process only.
    var selectedPIDs: Set<pid_t> = [] {
        // Collapse the environment when the inspected process changes (including to "several
        // selected"), so revealing one process's variables (which often hold secrets) never
        // reveals another's.
        didSet {
            if Self.sole(selectedPIDs) != Self.sole(oldValue) {
                isEnvironmentRevealed = false
                isOpenFilesExpanded = false
                isThreadsExpanded = false
                niceDraft = nil
                reniceError = nil
            }
        }
    }

    /// The process the inspector shows: the selection when exactly one row is selected, else
    /// nil. Setting it selects that one process (or nothing).
    var selectedPID: pid_t? {
        get { Self.sole(selectedPIDs) }
        set { selectedPIDs = newValue.map { [$0] } ?? [] }
    }

    private static func sole(_ pids: Set<pid_t>) -> pid_t? {
        pids.count == 1 ? pids.first : nil
    }

    /// The selected processes' latest rows, in table-sample order; exited ones drop out.
    var selectedRows: [ProcessInfoRow] {
        rows.filter { selectedPIDs.contains($0.pid) }
    }
    /// The selected process's nice value; nil when none selected or unreadable.
    private(set) var selectedNice: Int32?
    /// The value the inspector's stepper shows before it is applied; nil means "the current
    /// value". Cleared on selection change so one process's draft never applies to another.
    var niceDraft: Int32?
    /// The last renice failure for the selected process, shown inline in the inspector.
    var reniceError: String?
    /// Whether the inspector's Environment section is expanded. Collapsed by default.
    /// Held here rather than as view @State so the reset rule above is testable.
    var isEnvironmentRevealed = false
    /// Whether the inspector's Open Files group is expanded. Collapsed by default and on every
    /// selection change: a big app's hundreds of descriptors shouldn't stay open while you
    /// click through processes, and paths can be private too.
    var isOpenFilesExpanded = false
    /// Whether the inspector's Threads group is expanded; collapsed on selection change, as
    /// Open Files is (big apps run hundreds of threads).
    var isThreadsExpanded = false
    /// The selected process's threads, busiest first; nil when none selected or denied.
    private(set) var selectedThreads: [ThreadInfo]?
    /// Cumulative disk I/O and energy for the selected process; nil when none selected or denied.
    private(set) var selectedUsage: ProcessResourceUsage?
    /// Per-second rates since the previous tick; nil on the first tick after a selection change.
    private(set) var selectedUsageRates: ProcessUsageRates?
    /// The reading the rates are measured from, tagged with its process so a new selection
    /// never takes a rate against another process's counters.
    private var lastUsage: (pid: pid_t, usage: ProcessResourceUsage, nanos: UInt64)?
    /// Network traffic over the selected process's open sockets; nil when none selected or the
    /// framework is missing.
    private(set) var selectedNetwork: ProcessNetworkUsage?
    /// Per-second rates since the previous tick; nil on the first tick after a selection change.
    private(set) var selectedNetworkRates: SocketRates?
    /// False when per-socket counts can't be read (the private framework is missing).
    private(set) var isNetworkAvailable = true
    /// The reading the network rates are measured from.
    @ObservationIgnored private var lastNetwork: (usage: ProcessNetworkUsage, nanos: UInt64)?
    /// Detail for the selected process; nil when nothing selected or access is denied.
    private(set) var selectedDetails: ProcessDetails?
    /// Open network sockets for the selected process; empty when none selected or denied.
    private(set) var selectedPorts: [ProcessPort] = []
    /// Arguments and environment for the selected process; nil when none selected or denied.
    private(set) var selectedCommandLine: ProcessCommandLine?
    /// Open descriptors other than TCP/UDP sockets; nil when none selected or denied.
    private(set) var selectedOpenFiles: [OpenFile]?

    private let sampler: any ProcessSampling
    private let terminator: any ProcessTerminating
    private let detailProvider: any ProcessDetailProviding
    private let portProvider: any ProcessPortProviding
    private let commandLineProvider: any ProcessCommandLineProviding
    private let priorityProvider: any ProcessPriorityProviding
    private let fileProvider: any ProcessFileProviding
    private let threadProvider: any ProcessThreadProviding
    private let usageProvider: any ProcessResourceUsageProviding
    private let networkProvider: any SocketTrafficProviding
    private let now: @Sendable () -> UInt64
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(privileged: PrivilegedHelperClient.shared),
         terminator: any ProcessTerminating = HelperBackedTerminator(),
         detailProvider: any ProcessDetailProviding = ProcInfo(),
         portProvider: any ProcessPortProviding = ProcInfo(),
         commandLineProvider: any ProcessCommandLineProviding = ProcInfo(),
         priorityProvider: any ProcessPriorityProviding = ProcessPriority(),
         fileProvider: any ProcessFileProviding = ProcInfo(),
         threadProvider: any ProcessThreadProviding = ProcInfo(),
         usageProvider: any ProcessResourceUsageProviding = ProcInfo(),
         networkProvider: any SocketTrafficProviding = NStatSocketTraffic(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.terminator = terminator
        self.detailProvider = detailProvider
        self.portProvider = portProvider
        self.commandLineProvider = commandLineProvider
        self.priorityProvider = priorityProvider
        self.fileProvider = fileProvider
        self.threadProvider = threadProvider
        self.usageProvider = usageProvider
        self.networkProvider = networkProvider
        self.now = now
        self.interval = interval
    }

    /// One sample → publish rows, then refresh the selected process's details (live cadence).
    func refreshOnce() async {
        rows = await sampler.sample()
        // Drop exited processes from the selection (the table doesn't), so a finished batch
        // quit returns to "No Selection", a lone survivor gets the full inspector, and a PID
        // later reused by another program never turns up already selected.
        let live = Set(rows.map(\.pid))
        if !selectedPIDs.isSubset(of: live) { selectedPIDs.formIntersection(live) }
        refreshSelection()
        await refreshNetwork()
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

    /// Send `signal` to each target in turn (already confirmed by the user). A target whose
    /// PID is no longer in the latest sample under the same name is not signalled: the
    /// process exited, and the PID may now belong to a different program.
    func send(_ signal: ProcessSignal, to targets: [SignalTarget]) -> [SignalOutcome] {
        targets.map { target in
            let stillRunning = rows.contains { $0.pid == target.pid && $0.name == target.name }
            return SignalOutcome(target: target,
                                 result: stillRunning ? terminator.send(signal, to: target.pid) : .noSuchProcess)
        }
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
        selectedNice = selectedPID.flatMap { priorityProvider.nice(pid: $0) }
        selectedOpenFiles = selectedPID.flatMap { fileProvider.openFiles(pid: $0) }
        selectedThreads = selectedPID.flatMap { threadProvider.threads(pid: $0) }.map(ThreadInfo.sortedForDisplay)
        refreshUsage()
    }

    /// Network totals and rates for the selected process. Async (the framework answers on its
    /// own queue), so it runs after the synchronous `refreshSelection`.
    func refreshNetwork() async {
        guard let pid = selectedPID else {
            selectedNetwork = nil
            selectedNetworkRates = nil
            lastNetwork = nil
            return
        }
        guard let readings = await networkProvider.read() else {
            isNetworkAvailable = false
            selectedNetwork = nil
            selectedNetworkRates = nil
            lastNetwork = nil
            return
        }
        isNetworkAvailable = true
        guard pid == selectedPID else { return }        // selection moved while reading
        let usage = ProcessNetworkUsage(pid: pid, readings: readings)
        let nanos = now()
        if let last = lastNetwork, nanos > last.nanos {
            selectedNetworkRates = usage.rates(since: last.usage, seconds: Double(nanos - last.nanos) / 1_000_000_000)
        } else {
            selectedNetworkRates = nil
        }
        selectedNetwork = usage
        lastNetwork = (usage, nanos)
    }

    private func refreshUsage() {
        guard let pid = selectedPID, let usage = usageProvider.usage(pid: pid) else {
            selectedUsage = nil
            selectedUsageRates = nil
            lastUsage = nil
            return
        }
        let nanos = now()
        if let last = lastUsage, last.pid == pid, nanos > last.nanos {
            selectedUsageRates = ProcessUsageRates(from: last.usage, to: usage, overNanos: nanos - last.nanos)
        } else {
            selectedUsageRates = nil
        }
        selectedUsage = usage
        lastUsage = (pid, usage, nanos)
    }

    /// Set the nice value of process `pid` (already confirmed by the user). On success the
    /// draft is cleared and the value re-read; on failure the error is kept for the inspector.
    @discardableResult
    func renice(_ pid: pid_t, name: String, to value: Int32) -> ReniceResult {
        let result = priorityProvider.setNice(value, pid: pid)
        guard pid == selectedPID else { return result }   // selection moved while confirming
        reniceError = result.message(name: name)
        if result == .success { niceDraft = nil }
        selectedNice = priorityProvider.nice(pid: pid)
        return result
    }

    /// The selected process's latest sampled row (nil when nothing is selected or it has
    /// vanished). Reading observable `rows`/`selectedPID` here means a view that observes this
    /// model re-renders as rows update each tick — the key to a live-updating inspector.
    var selectedRow: ProcessInfoRow? {
        guard let pid = selectedPID else { return nil }
        return rows.first { $0.id == pid }
    }
}
