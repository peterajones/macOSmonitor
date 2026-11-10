import SwiftUI

/// Inspector content: renders three states — no selection, denied, or full detail.
/// Observes the model directly (rather than taking value snapshots) so it re-renders
/// live as the model's rows/details update each tick — presentation content otherwise
/// does not reliably re-evaluate on the presenting view's observable-state changes.
struct ProcessDetailView: View {
    let model: ProcessListModel

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
        } else {
            ContentUnavailableView("No Selection", systemImage: "cpu",
                                   description: Text("Select a process to see details."))
        }
    }
}
