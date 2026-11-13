import Foundation

/// One process a signal will go to, named as it was when the user confirmed, so the name can
/// be re-checked before sending (a PID can be reused by another program in the meantime).
struct SignalTarget: Equatable, Hashable, Sendable {
    let pid: pid_t
    let name: String
}

/// Which of a set of selected processes a Quit / Force Quit / Send Signal acts on.
struct ProcessBatch: Equatable, Sendable {
    /// The processes to signal, in table order.
    let targets: [SignalTarget]
    /// Visible selected processes that won't be signalled (not ours to signal, or this app
    /// alongside others).
    let skippedCount: Int

    /// Splits `pids` against the rows the table shows right now.
    ///
    /// - A pid not in `visibleRows` is ignored, not counted: a row hidden by the search or
    ///   filter, or a process that has exited, must never be signalled unseen.
    /// - A visible row we may not signal is skipped.
    /// - This app is a target only when it is the only visible pid: quitting itself part-way
    ///   through a batch would abandon the rest.
    static func make(pids: Set<pid_t>, visibleRows: [ProcessInfoRow], ownPID: pid_t = getpid()) -> ProcessBatch {
        let visible = visibleRows.filter { pids.contains($0.pid) }
        let ownIsAlone = visible.count == 1
        var targets: [SignalTarget] = []
        var skipped = 0
        for row in visible {
            if !row.canTerminate || (row.pid == ownPID && !ownIsAlone) {
                skipped += 1
            } else {
                targets.append(SignalTarget(pid: row.pid, name: row.name))
            }
        }
        return ProcessBatch(targets: targets, skippedCount: skipped)
    }

    /// "node ×3, esbuild, npm": each name once, with a count when it repeats; most common
    /// first, ties alphabetically.
    var groupedNames: String {
        var counts: [String: Int] = [:]
        for target in targets { counts[target.name, default: 0] += 1 }
        return counts
            .sorted { $0.value != $1.value
                ? $0.value > $1.value
                : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
            .joined(separator: ", ")
    }
}

/// A signal (Quit, Force Quit, Pause, …) awaiting confirmation.
/// Not file-private: `ContentView` owns this state so it survives navigation.
struct PendingTermination: Identifiable {
    let id = UUID()
    let targets: [SignalTarget]
    let skippedCount: Int
    let signal: ProcessSignal

    /// The request for `batch`, or nil when there is nothing in it we may signal.
    static func request(for batch: ProcessBatch, signal: ProcessSignal) -> PendingTermination? {
        guard !batch.targets.isEmpty else { return nil }
        return PendingTermination(targets: batch.targets, skippedCount: batch.skippedCount, signal: signal)
    }

    /// One target keeps the single-process wording (name and PID); several are counted.
    var title: String {
        if targets.count == 1 { return signal.confirmTitle(name: targets[0].name) }
        return signal.confirmTitle(count: targets.count)
    }

    var message: String {
        let body = targets.count == 1
            ? signal.confirmMessage(name: targets[0].name, pid: targets[0].pid)
            : signal.confirmMessage(groupedNames: ProcessBatch(targets: targets, skippedCount: 0).groupedNames,
                                    count: targets.count)
        return skippedCount > 0 ? body + "\n\n" + ProcessSignal.skippedNote(skippedCount) : body
    }
}

/// How sending a signal to one target went.
struct SignalOutcome: Equatable, Sendable {
    let target: SignalTarget
    let result: TerminationResult

    /// One message for whatever failed; nil when everything succeeded (a quit process simply
    /// drops off the next refresh). A single target keeps the single-process wording.
    static func failureMessage(_ outcomes: [SignalOutcome], signal: ProcessSignal) -> String? {
        let failures = outcomes.filter { $0.result != .success }
        guard !failures.isEmpty else { return nil }
        let verb = signal.actionTitle.lowercased()

        if outcomes.count == 1, let only = failures.first {
            let name = only.target.name
            switch only.result {
            case .success:          return nil
            case .denied:           return "Couldn’t \(verb) “\(name)”: permission denied."
            case .noSuchProcess:    return "“\(name)” is no longer running."
            case .refusedSelfPause: return "macOSmonitor can’t pause itself: nothing would be left to resume it."
            case .failure(let reason): return "Couldn’t \(verb) “\(name)”: \(reason)."
            }
        }

        let listed = failures.map { "\($0.target.name) (\(reason($0.result)))" }.joined(separator: "; ")
        let succeeded = outcomes.count - failures.count
        return "\(signal.actionTitle) \(succeeded) of \(outcomes.count) processes. Couldn’t \(verb): \(listed)."
    }

    private static func reason(_ result: TerminationResult) -> String {
        switch result {
        case .success:          "succeeded"
        case .denied:           "permission denied"
        case .noSuchProcess:    "no longer running"
        case .refusedSelfPause: "can’t pause itself"
        case .failure(let reason): reason
        }
    }
}

/// The inspector's stand-in when several processes are selected.
struct SelectionSummary: Equatable {
    let title: String
    let detail: String

    /// Nil unless several are selected. Names only the rows shown now, because those are what
    /// Quit acts on; selected rows hidden by the search or filter are counted, not named.
    init?(pids: Set<pid_t>, visibleRows: [ProcessInfoRow]) {
        guard pids.count > 1 else { return nil }
        let visible = visibleRows.filter { pids.contains($0.pid) }
        let names = ProcessBatch(targets: visible.map { SignalTarget(pid: $0.pid, name: $0.name) },
                                 skippedCount: 0).groupedNames
        let hidden = pids.count - visible.count
        title = "\(pids.count) Processes Selected"
        switch hidden {
        case 0:  detail = names
        case 1:  detail = names + "\n1 hidden by the current search or filter won’t be signalled."
        default: detail = names + "\n\(hidden) hidden by the current search or filter won’t be signalled."
        }
    }
}
