import SwiftUI

/// Inspector content: renders three states — no selection, denied, or full detail.
/// Observes the model directly (rather than taking value snapshots) so it re-renders
/// live as the model's rows/details update each tick — presentation content otherwise
/// does not reliably re-evaluate on the presenting view's observable-state changes.
struct ProcessDetailView: View {
    let model: ProcessListModel

    var body: some View {
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
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "cpu",
                                   description: Text("Select a process to see details."))
        }
    }
}
