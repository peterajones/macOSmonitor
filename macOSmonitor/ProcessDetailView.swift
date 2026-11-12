import SwiftUI

/// Inspector content: renders three states — no selection, denied, or full detail.
/// Observes the model directly (rather than taking value snapshots) so it re-renders
/// live as the model's rows/details update each tick — presentation content otherwise
/// does not reliably re-evaluate on the presenting view's observable-state changes.
struct ProcessDetailView: View {
    let model: ProcessListModel

    /// A nice change awaiting confirmation. Transient view state: losing it on navigation
    /// just cancels the dialog, which is the right outcome anyway.
    @State private var pendingRenice: PendingRenice?

    private let isRoot = getuid() == 0

    var body: some View {
        @Bindable var model = model   // for the Environment disclosure's isExpanded binding

        if let row = model.selectedRow {
            Form {
                Section("Process") {
                    LabeledContent("Name", value: row.name)
                    LabeledContent("PID", value: String(row.pid))
                    LabeledContent("CPU %", value: row.cpuText)
                    LabeledContent("CPU Time", value: row.cpuTimeText)
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
                    // Collapsed by default, and again on every selection change (see
                    // ProcessListModel.selectedPID): environments often hold secrets (API
                    // tokens), so nothing shows until asked, e.g. while screen-sharing.
                    switch EnvironmentDisplay(model.selectedCommandLine) {
                    case .unavailable:
                        Text("Environment unavailable (permission denied).")
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
