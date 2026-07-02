import SwiftUI

/// Inspector content: renders three states — no selection, denied, or full detail.
struct ProcessDetailView: View {
    let row: ProcessInfoRow?
    let details: ProcessDetails?

    var body: some View {
        if let row {
            Form {
                Section("Process") {
                    LabeledContent("Name", value: row.name)
                    LabeledContent("PID", value: String(row.pid))
                    LabeledContent("CPU %", value: row.cpuPercent.map { String(format: "%.1f", $0) } ?? "—")
                    LabeledContent("Memory", value: row.memoryBytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                    } ?? "—")
                }
                if let details {
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
