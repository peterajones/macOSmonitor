import SwiftUI

/// Inspector content: renders three states — no selection, denied, or full detail.
/// Observes the model directly (rather than taking value snapshots) so it re-renders
/// live as the model's rows/details update each tick — presentation content otherwise
/// does not reliably re-evaluate on the presenting view's observable-state changes.
struct ProcessDetailView: View {
    let model: ProcessListModel
    /// The rows the table shows now, so a multi-selection summary names what Quit acts on.
    let visibleRows: [ProcessInfoRow]

    /// A nice change awaiting confirmation. Transient view state: losing it on navigation
    /// just cancels the dialog, which is the right outcome anyway.
    @State private var pendingRenice: PendingRenice?

    private let isRoot = getuid() == 0

    @AppStorage(CPUTimeFormat.storageKey) private var cpuTimeFormat: CPUTimeFormat = .adaptive

    var body: some View {
        @Bindable var model = model   // for the Environment disclosure's isExpanded binding

        if let summary = SelectionSummary(pids: model.selectedPIDs, visibleRows: visibleRows) {
            // Several selected: the inspector shows one process only, so it summarises.
            ContentUnavailableView(summary.title, systemImage: "cpu", description: Text(summary.detail))
        } else if let row = model.selectedRow {
            Form {
                Section("Process") {
                    LabeledContent("Name", value: row.name)
                    LabeledContent("PID", value: String(row.pid))
                    LabeledContent("CPU %", value: row.cpuText)
                    LabeledContent("CPU Time", value: row.cpuTimeText(cpuTimeFormat))
                    LabeledContent("Done for it by others",
                                   value: model.selectedUsage.map { cpuTimeFormat.string(nanos: $0.billedCPUNanos) } ?? "—")
                        .help("CPU time other processes spent working for this one, such as WindowServer drawing its windows. Not included in CPU Time.")
                    LabeledContent("Done by it for others",
                                   value: model.selectedUsage.map { cpuTimeFormat.string(nanos: $0.servicedCPUNanos) } ?? "—")
                        .help("CPU time this process spent working for other processes. Already part of its CPU Time.")
                    LabeledContent("GPU Time", value: cpuTimeFormat.string(nanos: row.gpuTimeNanos))
                    LabeledContent("Memory", value: row.memoryText)
                }
                prioritySection(row)
                if let details = model.selectedDetails {
                    Section("Details") {
                        LabeledContent("User", value: details.user)
                        LabeledContent("Status", value: details.status)
                        LabeledContent("Parent PID", value: String(details.parentPID))
                        LabeledContent("Threads", value: String(details.threadCount))
                        LabeledContent("Started",
                                       value: details.startDate.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("Path", value: details.path ?? "—")
                    }
                } else {
                    Section {
                        Text("Details unavailable (permission denied).")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Disk & Energy") {
                    if let usage = model.selectedUsage {
                        // Rates read straight from the model (no local snapshot; see CLAUDE.md).
                        LabeledContent("Read", value: "\(usage.readText)  ·  \(model.selectedUsageRates.map { SystemVitals.rate($0.readBytesPerSec) } ?? "—")")
                        LabeledContent("Written", value: "\(usage.writtenText)  ·  \(model.selectedUsageRates.map { SystemVitals.rate($0.writeBytesPerSec) } ?? "—")")
                        LabeledContent("Energy used", value: usage.energyText)
                        LabeledContent("Power", value: model.selectedUsageRates?.powerText ?? "—")
                    } else {
                        Text("Disk and energy unavailable (permission denied).")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Network") {
                    if let network = model.selectedNetwork, network.socketCount > 0 {
                        LabeledContent("Received", value: SocketCounts.text(network.counts.rxBytes, model.selectedNetworkRates?.rxPerSec))
                        LabeledContent("Sent", value: SocketCounts.text(network.counts.txBytes, model.selectedNetworkRates?.txPerSec))
                        Text("Totals cover its \(network.socketCount) open \(network.socketCount == 1 ? "socket" : "sockets"); closed ones aren’t counted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !model.isNetworkAvailable {
                        Text("Network usage unavailable.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No open sockets visible.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Arguments") {
                    // argv[0] is dropped: the Path row already names the executable.
                    if let arguments = model.selectedCommandLine?.arguments {
                        if arguments.count <= 1 {
                            Text("No arguments.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(arguments.dropFirst().enumerated()), id: \.offset) { _, argument in
                                Text(argument.isEmpty ? "\"\"" : argument)
                                    .monospaced()
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        Text("Arguments unavailable (permission denied).")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Ports") {
                    if model.selectedPorts.isEmpty {
                        Text("No open ports.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.selectedPorts.enumerated()), id: \.offset) { _, port in
                            Text(port.displayText)
                                .monospaced()
                        }
                    }
                }
                Section {
                    // Collapsed by default and on every selection change, like Open Files.
                    if let threads = model.selectedThreads {
                        DisclosureGroup("Threads (\(threads.count))", isExpanded: $model.isThreadsExpanded) {
                            ForEach(threads) { thread in
                                LabeledContent {
                                    Text("\(cpuTimeFormat.string(nanos: thread.cpuTimeNanos))  \(String(format: "%.1f%%", thread.cpuPercent))")
                                        .monospacedDigit()
                                } label: {
                                    Text(thread.displayName).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    } else {
                        Text("Threads unavailable (permission denied).")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    // Collapsed by default and on every selection change (see
                    // ProcessListModel.isOpenFilesExpanded).
                    if let files = model.selectedOpenFiles {
                        DisclosureGroup("Open Files (\(files.count))",
                                        isExpanded: $model.isOpenFilesExpanded) {
                            ForEach(files, id: \.fd) { file in
                                Text(file.displayText)
                                    .monospaced()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(file.displayText)
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        Text("Open files unavailable (permission denied).")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    // Collapsed by default, and again on every selection change (see
                    // ProcessListModel.selectedPID): environments often hold secrets (API
                    // tokens), so nothing shows until asked, e.g. while screen-sharing.
                    switch EnvironmentDisplay(model.selectedCommandLine) {
                    case .unavailable:
                        Text("Environment unavailable (permission denied).")
                            .foregroundStyle(.secondary)
                    case .hiddenByMacOS where model.isSelectionFromHelper:
                        // The helper never sends environments (see PrivilegedInspection).
                        Text("Environment isn’t shown for processes that aren’t yours.")
                            .foregroundStyle(.secondary)
                    case .hiddenByMacOS:
                        Text("Environment hidden by macOS for system processes.")
                            .foregroundStyle(.secondary)
                    case .variables(let variables):
                        DisclosureGroup("Environment (\(variables.count))",
                                        isExpanded: $model.isEnvironmentRevealed) {
                            ForEach(Array(variables.enumerated()), id: \.offset) { _, variable in
                                Text(variable)
                                    .monospaced()
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog(
                pendingRenice.map { Nice.confirmTitle(name: $0.name, value: $0.to) } ?? "",
                isPresented: Binding(get: { pendingRenice != nil },
                                     set: { if !$0 { pendingRenice = nil } }),
                presenting: pendingRenice
            ) { item in
                Button("Set Nice \(item.to)") { model.renice(item.pid, name: item.name, to: item.to) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(Nice.confirmMessage(name: item.name, pid: item.pid, from: item.from,
                                         to: item.to, isRoot: isRoot))
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "cpu",
                                   description: Text("Select a process to see details."))
        }
    }

    // MARK: - Priority

    /// Nice value, editable for processes we own. Changes are staged in a draft and applied
    /// only after confirmation, because without root a raised nice value can't be lowered again.
    @ViewBuilder
    private func prioritySection(_ row: ProcessInfoRow) -> some View {
        Section("Priority") {
            if let current = model.selectedNice {
                if row.canTerminate {
                    let draft = model.niceDraft ?? current
                    Stepper(value: Binding(get: { draft },
                                           set: { model.niceDraft = $0 == current ? nil : $0 }),
                            in: Nice.allowedRange(current: current, isRoot: isRoot)) {
                        LabeledContent("Nice", value: String(draft))
                            .monospacedDigit()
                    }
                    if draft != current {
                        HStack {
                            Spacer()
                            Button("Revert") { model.niceDraft = nil }
                            Button("Apply…") {
                                pendingRenice = PendingRenice(pid: row.pid, name: row.name,
                                                              from: current, to: draft)
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                } else {
                    LabeledContent("Nice", value: String(current))
                        .monospacedDigit()
                }
                if let error = model.reniceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Priority unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A nice change awaiting confirmation in the inspector.
private struct PendingRenice: Identifiable {
    let id = UUID()
    let pid: pid_t
    let name: String
    let from: Int32
    let to: Int32
}
